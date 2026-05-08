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
#   - GITLAB_TOKEN env var set (personal or project access token with api scope)
#   - curl, jq
#
# Usage:
#   ./gitlab-code-review-eval.sh \
#       --gitlab-url https://gitlab.example.com \
#       --project-id 123                        \
#       --augment-username augment-bot           \
#       [--days 7]                               \
#       [--output report.json]
#
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DAYS=7
OUTPUT_FILE="augment-code-review-eval-report.json"
GITLAB_URL=""
PROJECT_ID=""
AUGMENT_USERNAME=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gitlab-url)       GITLAB_URL="$2";        shift 2 ;;
    --project-id)       PROJECT_ID="$2";        shift 2 ;;
    --augment-username) AUGMENT_USERNAME="$2";  shift 2 ;;
    --days)             DAYS="$2";              shift 2 ;;
    --output)           OUTPUT_FILE="$2";       shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^#//; s/^ //'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Validate required inputs ─────────────────────────────────────────────────
missing=()
[[ -z "$GITLAB_URL" ]]        && missing+=("--gitlab-url")
[[ -z "$PROJECT_ID" ]]        && missing+=("--project-id")
[[ -z "$AUGMENT_USERNAME" ]]  && missing+=("--augment-username")
[[ -z "${GITLAB_TOKEN:-}" ]]  && missing+=("GITLAB_TOKEN env var")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required parameters: ${missing[*]}" >&2
  exit 1
fi
for cmd in curl jq auggie; do
  command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is required but not found" >&2; exit 1; }
done

# ── Compute date window ──────────────────────────────────────────────────────
if date --version >/dev/null 2>&1; then
  AFTER_DATE=$(date -u -d "-${DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
else
  AFTER_DATE=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')
fi

echo "=== Augment Code Review Eval ==="
echo "GitLab:           $GITLAB_URL"
echo "Project ID:       $PROJECT_ID"
echo "Augment user:     $AUGMENT_USERNAME"
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

# ── 1. Fetch merged MRs in the time window ───────────────────────────────────
echo "Fetching merged MRs since $AFTER_DATE …"
ALL_MRS=$(gitlab_get_all "projects/${PROJECT_ID}/merge_requests?state=merged&updated_after=${AFTER_DATE}&order_by=updated_at&sort=desc")
TOTAL_MR_COUNT=$(echo "$ALL_MRS" | jq 'length')
echo "  Found $TOTAL_MR_COUNT merged MR(s) in window."

# ── 2. Filter to MRs that Augment commented on ───────────────────────────────
echo "Filtering to MRs reviewed by '$AUGMENT_USERNAME' …"
AUGMENT_MR_IIDS="[]"
for iid in $(echo "$ALL_MRS" | jq -r '.[].iid'); do
  notes=$(gitlab_get_all "projects/${PROJECT_ID}/merge_requests/${iid}/notes")
  has_augment=$(echo "$notes" | jq --arg u "$AUGMENT_USERNAME" '[.[] | select(.author.username == $u)] | length')
  if [[ "$has_augment" -gt 0 ]]; then
    AUGMENT_MR_IIDS=$(echo "$AUGMENT_MR_IIDS" | jq --argjson iid "$iid" '. + [$iid]')
  fi
done

AUGMENT_MR_COUNT=$(echo "$AUGMENT_MR_IIDS" | jq 'length')
echo "  $AUGMENT_MR_COUNT MR(s) were reviewed by Augment."
echo ""

if [[ "$AUGMENT_MR_COUNT" -eq 0 ]]; then
  echo "No MRs to evaluate. Exiting."
  jq -n --arg gl "$GITLAB_URL" --arg pid "$PROJECT_ID" --arg d "$DAYS" \
    '{gitlab_url:$gl, project_id:($pid|tonumber), window_days:($d|tonumber), evaluated_mrs:[], summary:{total_mrs:0, total_augment_comments:0, addressed_count:0, addressed_percent:0}}' \
    > "$OUTPUT_FILE"
  exit 0
fi

# ── 3. Run eval persona against each MR ──────────────────────────────────────
EVAL_RESULTS="[]"
INDEX=0
for iid in $(echo "$AUGMENT_MR_IIDS" | jq -r '.[]'); do
  INDEX=$((INDEX + 1))
  MR_URL="${GITLAB_URL}/$(curl -sf --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" | jq -r '.path_with_namespace')/-/merge_requests/${iid}"
  echo "[$INDEX/$AUGMENT_MR_COUNT] Evaluating MR !${iid}  ${MR_URL}"

  PROMPT="Evaluate this merge request ${MR_URL} and give me the % of comments from augment that were addressed. The Augment service account username on GitLab is '${AUGMENT_USERNAME}'. Return the result as a JSON object with the structure: {repo, mr_number, total_comments, augment_total_comments, augment_addressed_count, augment_addressed_percent, automated_eval_comments:[...]}. Output ONLY the JSON, no markdown fences."

  EVAL_OUTPUT=$(auggie --persona augment-code-review-eval --print "$PROMPT" 2>/dev/null || true)

  # Try to extract JSON from the response (the persona returns a JSON block)
  MR_JSON=$(echo "$EVAL_OUTPUT" | sed -n '/^{/,/^}/p' | head -1 || true)
  if echo "$MR_JSON" | jq empty 2>/dev/null; then
    EVAL_RESULTS=$(echo "$EVAL_RESULTS" | jq --argjson mr "$MR_JSON" '. + [$mr]')
    ADDR=$(echo "$MR_JSON" | jq '.augment_addressed_percent // 0')
    echo "  ✓ Addressed: ${ADDR}%"
  else
    # If structured JSON extraction failed, try grabbing the largest JSON blob
    MR_JSON=$(echo "$EVAL_OUTPUT" | grep -oP '\{[^{}]*("automated_eval_comments")[^}]*\}' | head -1 || true)
    if [[ -n "$MR_JSON" ]] && echo "$MR_JSON" | jq empty 2>/dev/null; then
      EVAL_RESULTS=$(echo "$EVAL_RESULTS" | jq --argjson mr "$MR_JSON" '. + [$mr]')
      ADDR=$(echo "$MR_JSON" | jq '.augment_addressed_percent // 0')
      echo "  ✓ Addressed: ${ADDR}%"
    else
      echo "  ⚠ Could not parse eval output for MR !${iid} — skipping"
      SKIPPED=$(jq -n --arg iid "$iid" --arg url "$MR_URL" '{mr_number:($iid|tonumber), url:$url, error:"failed to parse eval output"}')
      EVAL_RESULTS=$(echo "$EVAL_RESULTS" | jq --argjson s "$SKIPPED" '. + [$s]')
    fi
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
