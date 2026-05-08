# Augment Code Review Eval

Evaluate the quality of Augment's automated code reviews on GitLab merge requests.

This script finds merged MRs that Augment reviewed, runs the `augment-code-review-eval` persona against each one, and produces a consolidated JSON report with breakdowns by severity, category, subcategory, and emoji reactions.

## Prerequisites

- **auggie CLI** installed and authenticated (`npm install -g @augmentcode/auggie && auggie login`)
- **GITLAB_TOKEN** env var — a GitLab personal or project access token with `api` scope
- **curl**, **jq**, **bc** available on PATH
- A GitLab MCP server configured for the auggie CLI so the eval persona can read MR diffs and comments (see [Augment docs](https://docs.augmentcode.com))

## Usage

```bash
export GITLAB_TOKEN="glpat-xxxxxxxxxxxx"

./gitlab-code-review-eval.sh \
    --gitlab-url https://gitlab.example.com \
    --project-id 123 \
    --augment-username augment-bot \
    --days 14 \
    --output my-report.json
```

### Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--gitlab-url` | ✅ | — | Base URL of your GitLab instance |
| `--project-id` | ✅ | — | Numeric GitLab project ID |
| `--augment-username` | ✅ | — | Username of the Augment service account on GitLab |
| `--days` | | `7` | Number of days to look back for merged MRs |
| `--output` | | `augment-code-review-eval-report.json` | Output file path |

## How It Works

1. **Discover MRs** — Queries the GitLab API for all merged MRs updated within the time window
2. **Filter** — Keeps only MRs where the Augment service account left comments
3. **Evaluate** — Runs `auggie --persona augment-code-review-eval --print` against each MR
4. **Report** — Consolidates per-MR results into a single JSON report with breakdowns

## Output

The report JSON has the following structure:

```json
{
  "gitlab_url": "https://gitlab.example.com",
  "project": "group/repo",
  "project_id": 123,
  "window_days": 7,
  "window_after": "2025-01-01T00:00:00Z",
  "generated_at": "2025-01-08T12:00:00Z",
  "summary": {
    "total_mrs_evaluated": 5,
    "total_augment_comments": 23,
    "total_addressed": 19,
    "overall_addressed_percent": 82.6
  },
  "breakdowns": {
    "by_severity": [
      { "value": "high", "count": 8, "percent": 34.8, "addressed_count": 6, "addressed_percent": 75.0 }
    ],
    "by_primary_category": [
      { "value": "security", "count": 5, "percent": 21.7, "addressed_count": 5, "addressed_percent": 100.0 }
    ],
    "by_subcategory": [
      { "value": "security:secret-pii-exposure", "count": 3, "percent": 13.0, "addressed_count": 3, "addressed_percent": 100.0 }
    ],
    "by_emoji": [
      { "value": "👍", "count": 10, "percent": 43.5, "addressed_count": 10, "addressed_percent": 100.0 }
    ]
  },
  "evaluated_mrs": [ ]
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
