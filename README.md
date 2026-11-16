# slack-notif-action

Composite GitHub Action that posts a Block Kit summary of a workflow run to a Slack incoming webhook.

The message contains a coloured attachment with the repository and overall status, the triggering branch/tag/PR, the commit, the actor, a per-job pass/fail breakdown, and a button linking to the run.

## Usage

Add a `notify` job that depends on every job you want reported, and pass `toJSON(needs)` in:

```yaml
jobs:
  quality: ...
  unit-test: ...
  docker: ...

  notify:
    needs: [quality, unit-test, docker]
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: nodecraft/slack-notif-action@v1
        with:
          webhook: ${{ secrets.SLACK_WEBHOOK }}
          needs: ${{ toJSON(needs) }}
```

No `if:` guard on the webhook is needed. When `webhook` is empty (forked PRs don't get secrets) the action logs a notice and exits successfully.

The job receives your webhook secret, so for supply chain safety consider pinning to a full commit SHA instead of `@v1`:

```yaml
      - uses: nodecraft/slack-notif-action@<commit-sha> # v1.x.y
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `webhook` | `''` | Slack incoming webhook URL. Empty skips the notification. |
| `needs` | `''` | The calling job's `needs` context as JSON. Drives the job breakdown and overall status. |
| `status` | `''` | Overall status override (`success`, `failure`, `cancelled`). Derived from `needs` when unset. |
| `fail-on-skipped` | `true` | Treat skipped jobs as a failure. Set `false` if you have intentionally conditional jobs. |
| `name` | repository name | Display name in the message header. |
| `dry-run` | `false` | Build and print the payload without posting it. |

## Outputs

| Output | Description |
| --- | --- |
| `status` | Status used in the message: `success`, `failure`, `cancelled`, or `skipped` when no webhook was provided. |

## Status derivation

With `needs` supplied, the overall status is the worst result across all needed jobs:

1. any `failure` → `failure`
2. any `cancelled` → `cancelled`
3. any `skipped` → `failure` (unless `fail-on-skipped: false`)
4. otherwise → `success`

Without `needs`, pass `status: ${{ job.status }}` (or your own value) to report something meaningful.

## Notes

- Requires `jq` and `curl`, both present on GitHub-hosted runners.
- Slack mrkdwn special characters (`&`, `<`, `>`) in PR titles, commit subjects, and usernames are escaped.
