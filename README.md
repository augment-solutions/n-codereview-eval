# Augment Code Review Eval For Gitlab

Evaluate the quality of Augment's automated code reviews on GitLab merge requests.

This script finds merged MRs that Augment reviewed, runs the `augment-code-review-eval` persona against each one, and produces a consolidated JSON report with breakdowns by severity, category, subcategory, and emoji reactions.

## Prerequisites

- **auggie CLI** installed and authenticated (`npm install -g @augmentcode/auggie && auggie login`)
- **glab CLI** installed ([gitlab.com/gitlab-org/cli](https://gitlab.com/gitlab-org/cli)) — the eval persona uses `glab` to fetch MR data
- **GITLAB_TOKEN** env var — a GitLab personal or project access token with `api` scope (used by both the script and `glab`)
- **curl**, **jq**, **bc** available on PATH

## Quick Start

```bash
git clone https://github.com/augment-solutions/n-codereview-eval.git && cd n-codereview-eval
```

Then run the eval:

```bash
GITLAB_TOKEN="glpat-XXX" ./gitlab-code-review-eval.sh \
  --repo https://gitlab.com/augmentcode-sa/ecomm-stack \
  --gitlab-service-account-name service_account_project_80395882_4cec11437b042730ca8ca95a0fb39a3c \
  --include-open \
  --days 10 \
  --max-mrs-to-review 3
```

### Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--repo` | ✅ | — | GitLab repo — full URL (`https://gitlab.com/group/project`) or namespace path (`group/project`) |
| `--gitlab-service-account-name` | ✅ | — | The `@username` (without the `@`) of the GitLab service account used by Augment, e.g. `service_account_project_80395882_4cec11437b042730ca8ca95a0fb39a3c` |
| `--gitlab-url` | | `https://gitlab.com` | Base URL of your GitLab instance (auto-detected from `--repo` URL) |
| `--project-id` | | *(auto-resolved)* | Numeric project ID (auto-resolved from `--repo` if not provided) |
| `--include-open` | | *(off)* | Also include open (not yet merged) MRs in the evaluation |
| `--max-mrs-to-review` | | *(all)* | Maximum number of MRs to evaluate |
| `--days` | | `7` | Number of days to look back for MRs |
| `--output` | | `augment-code-review-eval-report.json` | Output file path |

## How It Works

1. **Discover MRs** — Queries the GitLab API for all merged MRs updated within the time window
2. **Filter** — Keeps only MRs where the Augment service account left comments
3. **Evaluate** — Runs `auggie --persona augment-code-review-eval --print` against each MR (~60–90s per MR)
4. **Report** — Consolidates per-MR results into a single JSON report with breakdowns

## Example Run

```
Resolving project ID for 'augmentcode-sa/ecomm-stack' …
  Resolved to project ID: 80395882
=== Augment Code Review Eval ===
GitLab:           https://gitlab.com
Project:          augmentcode-sa/ecomm-stack
Project ID:       80395882
Service account:  service_account_project_80395882_4cec11437b042730ca8ca95a0fb39a3c
Window:           last 10 days (after 2026-04-28T20:31:00Z)
Output:           augment-code-review-eval-report.json

Fetching all MRs (merged + open) since 2026-04-28T20:31:00Z …
  Found 7 MR(s) in window.
Filtering to MRs reviewed by 'service_account_project_80395882_4cec11437b042730ca8ca95a0fb39a3c' …
  6 MR(s) were reviewed by Augment.
  Limiting to 3 MR(s) (--max-mrs-to-review).

Running evaluations (300s timeout each) …

[1/3] Evaluating MR !173  https://gitlab.com/augmentcode-sa/ecomm-stack/-/merge_requests/173 …
  ✓ MR !173 — Addressed: 100.0% (70s)

[2/3] Evaluating MR !170  https://gitlab.com/augmentcode-sa/ecomm-stack/-/merge_requests/170 …
  ✓ MR !170 — Addressed: 100.0% (62s)

[3/3] Evaluating MR !172  https://gitlab.com/augmentcode-sa/ecomm-stack/-/merge_requests/172 …
  ✓ MR !172 — Addressed: 100.0% (69s)

Building consolidated report …

=== Report Summary ===
  MRs evaluated:            3
  Total Augment comments:   3
  Addressed:                3
  Overall addressed rate:   100.0%

  --- By Severity ---
    unknown     3       100%    addr: 3/3 (100%)

  --- By Primary Category ---
    tests-quality       3       100%    addr: 3/3 (100%)

  --- By Subcategory ---
    tests-quality:coverage-gaps 3       100%    addr: 3/3 (100%)

  --- By Emoji ---
    none        3       100%    addr: 3/3 (100%)

Full report written to: augment-code-review-eval-report.json
```

## Output

After the run, `cat augment-code-review-eval-report.json` produces:

```json
{
  "gitlab_url": "https://gitlab.com",
  "project": "augmentcode-sa/ecomm-stack",
  "project_id": 80395882,
  "window_days": 10,
  "window_after": "2026-04-28T20:31:00Z",
  "generated_at": "2026-05-08T20:34:26Z",
  "summary": {
    "total_mrs_evaluated": 3,
    "total_augment_comments": 3,
    "total_addressed": 3,
    "overall_addressed_percent": 100.0
  },
  "breakdowns": {
    "by_severity": [
      { "value": "unknown", "count": 3, "percent": 100, "addressed_count": 3, "addressed_percent": 100 }
    ],
    "by_primary_category": [
      { "value": "tests-quality", "count": 3, "percent": 100, "addressed_count": 3, "addressed_percent": 100 }
    ],
    "by_subcategory": [
      { "value": "tests-quality:coverage-gaps", "count": 3, "percent": 100, "addressed_count": 3, "addressed_percent": 100 }
    ],
    "by_emoji": [
      { "value": "none", "count": 3, "percent": 100, "addressed_count": 3, "addressed_percent": 100 }
    ]
  },
  "evaluated_mrs": [
    {
      "repo": "augmentcode-sa/ecomm-stack",
      "mr_number": 173,
      "total_comments": 1,
      "augment_total_comments": 1,
      "augment_addressed_count": 1,
      "augment_addressed_percent": 100.0,
      "automated_eval_comments": [
        {
          "addressed": true,
          "actionable": true,
          "comment_id": "3307085652",
          "primary_category": "tests-quality",
          "subcategory": "tests-quality:coverage-gaps",
          "resolved": null,
          "is_outdated": null,
          "emoji": null,
          "severity": null,
          "author_type": "Augment",
          "reply_count": 0
        }
      ]
    }
  ]
}
```

### Breakdown Fields

Each entry in a breakdown array contains:

| Field | Description |
|-------|-------------|
| `value` | The severity / category / subcategory / emoji value |
| `count` | Number of Augment comments with this value |
| `percent` | Share of total Augment comments |
| `addressed_count` | How many in this bucket were addressed |
| `addressed_percent` | Addressed rate within this bucket |

## License

Internal use — Augment Code.
