#!/usr/bin/env bash
set -euo pipefail

if [ -z "${SLACK_WEBHOOK:-}" ]; then
  echo "::notice title=Slack notification::No webhook provided, skipping."
  echo "status=skipped" >> "$GITHUB_OUTPUT"
  exit 0
fi

# `needs` is empty for standalone jobs, but jq needs an object either way
results="${JOB_RESULTS:-}"
if [ -z "$results" ] || ! jq -e 'type == "object"' <<< "$results" > /dev/null 2>&1; then
  results='{}'
fi

overall="${STATUS_OVERRIDE:-}"
if [ -z "$overall" ]; then
  overall=$(jq -r --arg strict "${FAIL_ON_SKIPPED:-true}" '
    [.[].result] as $r
    | if ($r | length) == 0 then "success"
      elif ($r | any(. == "failure")) then "failure"
      elif ($r | any(. == "cancelled")) then "cancelled"
      elif $strict == "true" and ($r | any(. == "skipped")) then "failure"
      else "success" end
  ' <<< "$results")
fi

case "$overall" in
  success) color='#2eb886'; heading='✅ CI passed' ;;
  cancelled) color='#8d8d8d'; heading='🚫 CI cancelled' ;;
  failure) color='#d63d2e'; heading='❌ CI failed' ;;
  *) echo "::error title=Slack notification::Unsupported status '$overall'"; exit 1 ;;
esac

repo_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
run_url="${repo_url}/actions/runs/${GITHUB_RUN_ID}"
commit_url="${repo_url}/commit/${HEAD_SHA}"

subject="${COMMIT_MESSAGE:-}"
subject="${subject%%$'\n'*}"

# keyed off the payload rather than the event name so pull_request_target works too
if [ -n "${PR_URL:-}" ]; then
  source_label='Pull request'
  source_url="$PR_URL"
  source_text="#${PR_NUMBER} ${PR_TITLE}"
  # the PR title already carries the message; don't repeat it on the commit line
  subject=''
elif [ "${GITHUB_REF_TYPE:-branch}" = 'tag' ]; then
  source_label='Tag'
  source_url="${repo_url}/releases/tag/${GITHUB_REF_NAME}"
  source_text="$GITHUB_REF_NAME"
else
  source_label='Branch'
  source_url="${repo_url}/tree/${GITHUB_REF_NAME}"
  source_text="$GITHUB_REF_NAME"
fi

payload="${RUNNER_TEMP:-/tmp}/slack-payload.json"

jq -n \
  --arg color "$color" \
  --arg heading "$heading" \
  --arg overall "$overall" \
  --arg name "${DISPLAY_NAME:-${GITHUB_REPOSITORY#*/}}" \
  --arg source_label "$source_label" \
  --arg source_url "$source_url" \
  --arg source_text "$source_text" \
  --arg commit_url "$commit_url" \
  --arg sha "${HEAD_SHA:0:7}" \
  --arg subject "$subject" \
  --arg actor "$GITHUB_ACTOR" \
  --arg actor_url "${GITHUB_SERVER_URL}/${GITHUB_ACTOR}" \
  --arg run_url "$run_url" \
  --argjson results "$results" \
  '
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def icon: if . == "success" then "✅" elif . == "cancelled" then "🚫" elif . == "skipped" then "⏭️" else "❌" end;
  ($results | to_entries) as $jobs
  | {
    attachments: [{
      color: $color,
      blocks: [
        {
          type: "header",
          text: { type: "plain_text", text: "\($name) · \($heading)", emoji: true }
        },
        {
          type: "section",
          fields: [
            { type: "mrkdwn", text: "*\($source_label)*\n<\($source_url)|\($source_text | esc)>" },
            { type: "mrkdwn", text: ("*Commit*\n<\($commit_url)|\($sha)>" + (if $subject == "" then "" else " \($subject | esc)" end)) },
            { type: "mrkdwn", text: "*Author*\n<\($actor_url)|\($actor | esc)>" },
            (if ($jobs | length) == 0 then empty else
              { type: "mrkdwn", text: "*Jobs*\n\($jobs | map(select(.value.result == "success")) | length)/\($jobs | length) passed" }
            end)
          ]
        },
        (if ($jobs | length) == 0 then empty else
          {
            type: "section",
            text: {
              type: "mrkdwn",
              text: ($jobs | map("\(.value.result | icon)  \(.key | gsub("-"; " "))") | join("\n"))
            }
          }
        end),
        {
          type: "actions",
          elements: [{
            type: "button",
            text: { type: "plain_text", text: "View workflow run", emoji: true },
            url: $run_url,
            style: (if $overall == "success" then "primary" else "danger" end)
          }]
        }
      ]
    }]
  }' > "$payload"

echo "status=$overall" >> "$GITHUB_OUTPUT"

if [ "${DRY_RUN:-false}" = 'true' ]; then
  echo "::notice title=Slack notification::Dry run, payload not sent."
  jq . "$payload"
  exit 0
fi

curl -sS --fail-with-body --retry 3 --retry-connrefused \
  -X POST \
  -H 'Content-Type: application/json' \
  --data @"$payload" \
  "$SLACK_WEBHOOK"
echo
