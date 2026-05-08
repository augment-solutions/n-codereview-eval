#!/usr/bin/env bash
#
# gitlab-code-review-eval.sh
#
# Finds all merged GitLab MRs reviewed by Augment over a given period,
# runs the augment-code-review-eval persona against each, and produces
# a consolidated JSON report.
#
# Prerequisites:
#   - auggie CLI installed and authenticated (`auggie login`)
#   - glab CLI installed (https://gitlab.com/gitlab-org/cli)
#   - GITLAB_TOKEN env var set (personal or project access token with api scope)
#   - curl, jq
#
# Usage:
#   ./gitlab-code-review-eval.sh \
#       --repo https://gitlab.example.com/group/project   \
#       --gitlab-service-account-name augment-bot          \
#       [--days 7]                                         \
#       [--output report.json]
#
#   --repo accepts a full GitLab URL (https://gitlab.com/group/project)
#         or a namespace path (group/project) when combined with --gitlab-url.
#
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DAYS=7
OUTPUT_FILE="augment-code-review-eval-report.json"
GITLAB_URL=""
PROJECT_ID=""
REPO=""
GITLAB_SERVICE_ACCOUNT=""
INCLUDE_OPEN=false
MAX_MRS=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)             REPO="$2";              shift 2 ;;
    --gitlab-url)       GITLAB_URL="$2";        shift 2 ;;
    --project-id)       PROJECT_ID="$2";        shift 2 ;;
    --gitlab-service-account-name) GITLAB_SERVICE_ACCOUNT="$2";  shift 2 ;;
    --include-open)     INCLUDE_OPEN=true;      shift ;;
    --max-mrs-to-review) MAX_MRS="$2";         shift 2 ;;
    --days)             DAYS="$2";              shift 2 ;;
    --output)           OUTPUT_FILE="$2";       shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^#//; s/^ //'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Resolve repo → GITLAB_URL + PROJECT_ID ────────────────────────────────────
if [[ -n "$REPO" ]]; then
  # Full URL: https://gitlab.example.com/group/subgroup/project
  if [[ "$REPO" =~ ^https?:// ]]; then
    # Strip protocol + host to get the path
    GITLAB_URL=$(echo "$REPO" | sed -E 's|(https?://[^/]+).*|\1|')
    PROJECT_PATH=$(echo "$REPO" | sed -E 's|https?://[^/]+/||; s|/$||')
  else
    # Bare namespace path: group/project — requires --gitlab-url
    PROJECT_PATH="$REPO"
    if [[ -z "$GITLAB_URL" ]]; then
      GITLAB_URL="https://gitlab.com"
      echo "No --gitlab-url provided, defaulting to $GITLAB_URL"
    fi
  fi
fi

# ── Validate required inputs ─────────────────────────────────────────────────
missing=()
[[ -z "$GITLAB_URL" && -z "$REPO" ]]  && missing+=("--repo")
[[ -z "$GITLAB_SERVICE_ACCOUNT" ]]    && missing+=("--gitlab-service-account-name")
[[ -z "${GITLAB_TOKEN:-}" ]]          && missing+=("GITLAB_TOKEN env var")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required parameters: ${missing[*]}" >&2
  exit 1
fi
for cmd in curl jq auggie glab; do
  command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is required but not found" >&2; exit 1; }
done

# ── Resolve PROJECT_ID from path if not provided ─────────────────────────────
if [[ -z "$PROJECT_ID" ]]; then
  if [[ -z "${PROJECT_PATH:-}" ]]; then
    echo "Error: either --repo or --project-id is required" >&2
    exit 1
  fi
  ENCODED_PATH=$(echo "$PROJECT_PATH" | sed 's|/|%2F|g')
  echo "Resolving project ID for '$PROJECT_PATH' …"
  PROJECT_INFO=$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL}/api/v4/projects/${ENCODED_PATH}")
  PROJECT_ID=$(echo "$PROJECT_INFO" | jq -r '.id')
  if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
    echo "Error: could not resolve project ID for '$PROJECT_PATH'. Check the repo path and your GITLAB_TOKEN permissions." >&2
    exit 1
  fi
  echo "  Resolved to project ID: $PROJECT_ID"
fi

# ── Compute date window ──────────────────────────────────────────────────────
if date --version >/dev/null 2>&1; then
  AFTER_DATE=$(date -u -d "-${DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
else
  AFTER_DATE=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')
fi

echo "=== Augment Code Review Eval ==="
echo "GitLab:           $GITLAB_URL"
echo "Project:          ${PROJECT_PATH:-$PROJECT_ID}"
echo "Project ID:       $PROJECT_ID"
echo "Service account:  $GITLAB_SERVICE_ACCOUNT"
echo "Window:           last $DAYS days (after $AFTER_DATE)"
echo "Output:           $OUTPUT_FILE"
echo ""

# ── Helper: paginated GitLab API GET ──────────────────────────────────────────
gitlab_get_all() {
  local endpoint="$1"
  local page=1
  local results="[]"
  while true; do
    local sep="&"; [[ "$endpoint" != *"?"* ]] && sep="?"
    local resp
    resp=$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "${GITLAB_URL}/api/v4/${endpoint}${sep}per_page=100&page=${page}")
    local count
    count=$(echo "$resp" | jq 'length')
    [[ "$count" -eq 0 ]] && break
    results=$(echo "$results $resp" | jq -s '.[0] + .[1]')
    page=$((page + 1))
  done
  echo "$results"
}

# ── 1. Fetch MRs in the time window ───────────────────────────────────────────
if [[ "$INCLUDE_OPEN" == true ]]; then
  echo "Fetching all MRs (merged + open) since $AFTER_DATE …"
  MERGED_MRS=$(gitlab_get_all "projects/${PROJECT_ID}/merge_requests?state=merged&updated_after=${AFTER_DATE}&order_by=updated_at&sort=desc")
  OPEN_MRS=$(gitlab_get_all "projects/${PROJECT_ID}/merge_requests?state=opened&updated_after=${AFTER_DATE}&order_by=updated_at&sort=desc")
  ALL_MRS=$(echo "$MERGED_MRS $OPEN_MRS" | jq -s '.[0] + .[1]')
else
  echo "Fetching merged MRs since $AFTER_DATE …"
  ALL_MRS=$(gitlab_get_all "projects/${PROJECT_ID}/merge_requests?state=merged&updated_after=${AFTER_DATE}&order_by=updated_at&sort=desc")
fi
TOTAL_MR_COUNT=$(echo "$ALL_MRS" | jq 'length')
echo "  Found $TOTAL_MR_COUNT MR(s) in window."

# ── 2. Filter to MRs that Augment commented on ───────────────────────────────
echo "Filtering to MRs reviewed by '$GITLAB_SERVICE_ACCOUNT' …"
AUGMENT_MR_IIDS="[]"
for iid in $(echo "$ALL_MRS" | jq -r '.[].iid'); do
  notes=$(gitlab_get_all "projects/${PROJECT_ID}/merge_requests/${iid}/notes")
  has_augment=$(echo "$notes" | jq --arg u "$GITLAB_SERVICE_ACCOUNT" '[.[] | select(.author.username == $u)] | length')
  if [[ "$has_augment" -gt 0 ]]; then
    AUGMENT_MR_IIDS=$(echo "$AUGMENT_MR_IIDS" | jq --argjson iid "$iid" '. + [$iid]')
  fi
done

AUGMENT_MR_COUNT=$(echo "$AUGMENT_MR_IIDS" | jq 'length')
echo "  $AUGMENT_MR_COUNT MR(s) were reviewed by Augment."

# ── Apply --max-mrs-to-review limit ──────────────────────────────────────────
if [[ -n "$MAX_MRS" && "$AUGMENT_MR_COUNT" -gt "$MAX_MRS" ]]; then
  echo "  Limiting to $MAX_MRS MR(s) (--max-mrs-to-review)."
  AUGMENT_MR_IIDS=$(echo "$AUGMENT_MR_IIDS" | jq --argjson n "$MAX_MRS" '.[:$n]')
  AUGMENT_MR_COUNT="$MAX_MRS"
fi
echo ""

if [[ "$AUGMENT_MR_COUNT" -eq 0 ]]; then
  echo "No MRs to evaluate. Exiting."
  jq -n --arg gl "$GITLAB_URL" --arg pid "$PROJECT_ID" --arg d "$DAYS" \
    '{gitlab_url:$gl, project_id:($pid|tonumber), window_days:($d|tonumber), evaluated_mrs:[], summary:{total_mrs:0, total_augment_comments:0, addressed_count:0, addressed_percent:0}}' \
    > "$OUTPUT_FILE"
  exit 0
fi

# ── 3. Run eval persona against each MR ──────────────────────────────────────
MR_TIMEOUT=300  # 5 minutes per MR
PROJECT_PATH_CACHED=$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" | jq -r '.path_with_namespace')

# Extract JSON from auggie output — tries multiple strategies
extract_json() {
  local output="$1"
  # Strategy 1: find a top-level JSON object spanning multiple lines
  local candidate
  candidate=$(echo "$output" | awk '
    /^{/ { capture=1; buf=$0; next }
    capture { buf=buf "\n" $0 }
    capture && /^}/ { print buf; capture=0 }
  ' | head -1 || true)
  if [[ -n "$candidate" ]] && echo "$candidate" | jq empty 2>/dev/null; then
    echo "$candidate"
    return 0
  fi
  # Strategy 2: extract the last JSON block (possibly embedded in text)
  candidate=$(echo "$output" | sed -n '/{/,/}/p' | tail -r 2>/dev/null | sed -n '/}/,/{/p' | tail -r 2>/dev/null || true)
  if [[ -n "$candidate" ]] && echo "$candidate" | jq empty 2>/dev/null; then
    echo "$candidate"
    return 0
  fi
  # Strategy 3: let jq try to parse each line that starts with {
  while IFS= read -r line; do
    if echo "$line" | jq empty 2>/dev/null; then
      echo "$line"
      return 0
    fi
  done < <(echo "$output" | grep '^{')
  return 1
}

echo "Running evaluations (${MR_TIMEOUT}s timeout each) …"
echo ""

EVAL_RESULTS="[]"
INDEX=0
for iid in $(echo "$AUGMENT_MR_IIDS" | jq -r '.[]'); do
  INDEX=$((INDEX + 1))
  MR_URL="${GITLAB_URL}/${PROJECT_PATH_CACHED}/-/merge_requests/${iid}"

  echo "[$INDEX/$AUGMENT_MR_COUNT] Evaluating MR !${iid}  ${MR_URL} …"
  START_TIME=$(date +%s)

  PROMPT="## CRITICAL INSTRUCTIONS — READ BEFORE DOING ANYTHING

This is a GitLab merge request. You MUST use the glab CLI to fetch all data.

### MANDATORY tool usage
- You MUST use the launch-process tool to run glab commands. The GITLAB_TOKEN env var is already set.
- Do NOT use web-fetch. Do NOT use github-api. Do NOT use any MCP server. Do NOT try to open URLs in a browser. Do NOT use curl.
- The ONLY way to get MR data is via glab CLI commands through launch-process.

### glab commands to run (in this order)
1. Get MR notes/comments: glab api projects/${PROJECT_ID}/merge_requests/${iid}/notes?per_page=100
2. Get MR changes/diff: glab api projects/${PROJECT_ID}/merge_requests/${iid}/changes
3. Get MR metadata: glab api projects/${PROJECT_ID}/merge_requests/${iid}

### What to evaluate
- MR URL: ${MR_URL}
- The Augment service account username on GitLab is: ${GITLAB_SERVICE_ACCOUNT}
- Identify all comments authored by that username
- For each such comment, determine if it was addressed by subsequent commits or replies
- Evaluate the % of comments from Augment that were addressed

### Required output format
Return ONLY a JSON object (no markdown fences, no explanation) with this structure:
{\"repo\": \"${PROJECT_PATH_CACHED}\", \"mr_number\": ${iid}, \"total_comments\": N, \"augment_total_comments\": N, \"augment_addressed_count\": N, \"augment_addressed_percent\": N.N, \"automated_eval_comments\": [{\"addressed\": true/false, \"actionable\": true/false, \"comment_id\": \"ID\", \"primary_category\": \"...\", \"subcategory\": \"...\", \"resolved\": true/false/null, \"is_outdated\": true/false, \"emoji\": \"...\", \"severity\": \"...\", \"author_type\": \"Augment\", \"reply_count\": N}]}"

  EVAL_STDERR=$(mktemp)
  EVAL_STDOUT=$(mktemp)
  # Run auggie with a timeout — use 'timeout' (Linux/GNU) or fall back to a
  # background-process approach on macOS where 'timeout' is not available.
  if command -v timeout >/dev/null 2>&1; then
    timeout "${MR_TIMEOUT}" env GITLAB_TOKEN="$GITLAB_TOKEN" auggie --persona augment-code-review-eval --print "$PROMPT" >"$EVAL_STDOUT" 2>"$EVAL_STDERR" || true
  else
    env GITLAB_TOKEN="$GITLAB_TOKEN" auggie --persona augment-code-review-eval --print "$PROMPT" >"$EVAL_STDOUT" 2>"$EVAL_STDERR" &
    AUGGIE_PID=$!
    ( sleep "${MR_TIMEOUT}" && kill "$AUGGIE_PID" 2>/dev/null ) &
    TIMER_PID=$!
    wait "$AUGGIE_PID" 2>/dev/null || true
    kill "$TIMER_PID" 2>/dev/null || true
    wait "$TIMER_PID" 2>/dev/null || true
  fi
  EVAL_OUTPUT=$(cat "$EVAL_STDOUT")
  rm -f "$EVAL_STDOUT"

  ELAPSED=$(( $(date +%s) - START_TIME ))

  # If auggie produced no stdout, show stderr to help debug
  if [[ -z "$EVAL_OUTPUT" ]]; then
    echo "  ⚠ MR !${iid} — auggie returned no output (${ELAPSED}s)"
    if [[ -s "$EVAL_STDERR" ]]; then
      echo "  stderr:"
      sed 's/^/    /' "$EVAL_STDERR"
    fi
    SKIPPED=$(jq -n --arg iid "$iid" --arg url "$MR_URL" '{mr_number:($iid|tonumber), url:$url, error:"auggie returned no output"}')
    EVAL_RESULTS=$(echo "$EVAL_RESULTS" | jq --argjson s "$SKIPPED" '. + [$s]')
    rm -f "$EVAL_STDERR"
    echo ""
    continue
  fi
  rm -f "$EVAL_STDERR"

  MR_JSON=""
  if MR_JSON=$(extract_json "$EVAL_OUTPUT"); then
    EVAL_RESULTS=$(echo "$EVAL_RESULTS" | jq --argjson mr "$MR_JSON" '. + [$mr]')
    ADDR=$(echo "$MR_JSON" | jq '.augment_addressed_percent // 0')
    echo "  ✓ MR !${iid} — Addressed: ${ADDR}% (${ELAPSED}s)"
  else
    SKIPPED=$(jq -n --arg iid "$iid" --arg url "$MR_URL" '{mr_number:($iid|tonumber), url:$url, error:"failed to parse eval output"}')
    EVAL_RESULTS=$(echo "$EVAL_RESULTS" | jq --argjson s "$SKIPPED" '. + [$s]')
    echo "  ⚠ MR !${iid} — Could not parse eval output (${ELAPSED}s)"
    echo "  Raw output (first 500 chars):"
    echo "    $(echo "$EVAL_OUTPUT" | head -c 500)"
  fi
  echo ""
done

# ── 4. Build consolidated report ─────────────────────────────────────────────
echo "Building consolidated report …"
PROJECT_PATH=$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" | jq -r '.path_with_namespace')

# Flatten all automated_eval_comments across MRs into a single array
ALL_COMMENTS=$(echo "$EVAL_RESULTS" | jq '[.[] | .automated_eval_comments // [] | .[]]')
TOTAL_AUGMENT_COMMENTS=$(echo "$EVAL_RESULTS" | jq '[.[] | .augment_total_comments // 0] | add // 0')
TOTAL_ADDRESSED=$(echo "$EVAL_RESULTS" | jq '[.[] | .augment_addressed_count // 0] | add // 0')
if [[ "$TOTAL_AUGMENT_COMMENTS" -gt 0 ]]; then
  OVERALL_PERCENT=$(echo "scale=1; $TOTAL_ADDRESSED * 100 / $TOTAL_AUGMENT_COMMENTS" | bc)
else
  OVERALL_PERCENT="0.0"
fi

# ── Build breakdowns by severity, primary_category, subcategory, emoji ──────
# Helper jq function: group an array of comments by a field and produce
# [{value, count, percent, addressed_count, addressed_percent}]
BREAKDOWN_JQ='
def breakdown(field):
  group_by(.[field])
  | map({
      value:             (.[0][field] // "unknown"),
      count:             length,
      percent:           ((length * 1000 / ($total | tonumber) + 5) / 10),
      addressed_count:   ([.[] | select(.addressed == true)] | length),
      addressed_percent: (if length > 0
                          then (([.[] | select(.addressed == true)] | length) * 1000 / length + 5) / 10
                          else 0 end)
    })
  | sort_by(-.count);
'

BREAKDOWNS=$(echo "$ALL_COMMENTS" | jq --arg total "$TOTAL_AUGMENT_COMMENTS" "
  ${BREAKDOWN_JQ}
  {
    by_severity:         ([.[] | . + {_sev: (.severity // \"unknown\")}] | group_by(._sev) | map({
                            value: .[0]._sev,
                            count: length,
                            percent: ((length * 1000 / (\$total | tonumber) + 5) / 10),
                            addressed_count: ([.[] | select(.addressed == true)] | length),
                            addressed_percent: (if length > 0 then (([.[] | select(.addressed == true)] | length) * 1000 / length + 5) / 10 else 0 end)
                          }) | sort_by(-.count)),
    by_primary_category: ([.[] | . + {_pc: (.primary_category // \"unknown\")}] | group_by(._pc) | map({
                            value: .[0]._pc,
                            count: length,
                            percent: ((length * 1000 / (\$total | tonumber) + 5) / 10),
                            addressed_count: ([.[] | select(.addressed == true)] | length),
                            addressed_percent: (if length > 0 then (([.[] | select(.addressed == true)] | length) * 1000 / length + 5) / 10 else 0 end)
                          }) | sort_by(-.count)),
    by_subcategory:      ([.[] | . + {_sc: (.subcategory // \"unknown\")}] | group_by(._sc) | map({
                            value: .[0]._sc,
                            count: length,
                            percent: ((length * 1000 / (\$total | tonumber) + 5) / 10),
                            addressed_count: ([.[] | select(.addressed == true)] | length),
                            addressed_percent: (if length > 0 then (([.[] | select(.addressed == true)] | length) * 1000 / length + 5) / 10 else 0 end)
                          }) | sort_by(-.count)),
    by_emoji:            ([.[] | . + {_em: (.emoji // \"none\")}] | group_by(._em) | map({
                            value: .[0]._em,
                            count: length,
                            percent: ((length * 1000 / (\$total | tonumber) + 5) / 10),
                            addressed_count: ([.[] | select(.addressed == true)] | length),
                            addressed_percent: (if length > 0 then (([.[] | select(.addressed == true)] | length) * 1000 / length + 5) / 10 else 0 end)
                          }) | sort_by(-.count))
  }
")

jq -n \
  --arg gl "$GITLAB_URL" \
  --arg proj "$PROJECT_PATH" \
  --arg pid "$PROJECT_ID" \
  --arg days "$DAYS" \
  --arg after "$AFTER_DATE" \
  --arg total_mr "$AUGMENT_MR_COUNT" \
  --arg total_comments "$TOTAL_AUGMENT_COMMENTS" \
  --arg addressed "$TOTAL_ADDRESSED" \
  --arg pct "$OVERALL_PERCENT" \
  --argjson mrs "$EVAL_RESULTS" \
  --argjson breakdowns "$BREAKDOWNS" \
  '{
    gitlab_url: $gl,
    project: $proj,
    project_id: ($pid | tonumber),
    window_days: ($days | tonumber),
    window_after: $after,
    generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    summary: {
      total_mrs_evaluated: ($total_mr | tonumber),
      total_augment_comments: ($total_comments | tonumber),
      total_addressed: ($addressed | tonumber),
      overall_addressed_percent: ($pct | tonumber)
    },
    breakdowns: $breakdowns,
    evaluated_mrs: $mrs
  }' > "$OUTPUT_FILE"

echo ""
echo "=== Report Summary ==="
echo "  MRs evaluated:            $AUGMENT_MR_COUNT"
echo "  Total Augment comments:   $TOTAL_AUGMENT_COMMENTS"
echo "  Addressed:                $TOTAL_ADDRESSED"
echo "  Overall addressed rate:   ${OVERALL_PERCENT}%"
echo ""

# ── Print breakdown tables ───────────────────────────────────────────────────
print_breakdown() {
  local title="$1"
  local key="$2"
  echo "  --- ${title} ---"
  echo "$BREAKDOWNS" | jq -r --arg k "$key" '.[$k][] | "    \(.value)\t\(.count)\t\(.percent)%\taddr: \(.addressed_count)/\(.count) (\(.addressed_percent)%)"'
  echo ""
}

print_breakdown "By Severity"         "by_severity"
print_breakdown "By Primary Category" "by_primary_category"
print_breakdown "By Subcategory"      "by_subcategory"
print_breakdown "By Emoji"            "by_emoji"

echo "Full report written to: $OUTPUT_FILE"
