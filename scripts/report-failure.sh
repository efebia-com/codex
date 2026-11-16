#!/usr/bin/env bash
# Open (or comment on) the release-failure issue for a failed release run.
#
# Usage: scripts/report-failure.sh <owner/repo> <run-id> <upstream-tag>
#
# The issue names the failed jobs and steps and quotes the end of their logs,
# up to the first error. While it is open, scheduled runs skip this upstream
# tag (see check-release.sh); closing it allows the next attempt.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq

[[ $# -eq 3 ]] || die "usage: $0 <owner/repo> <run-id> <upstream-tag>"
repo="$1"
run_id="$2"
tag="$3"
run_url="https://github.com/${repo}/actions/runs/${run_id}"
title="Release failed: upstream ${tag}"

body="$(mktemp)"
trap 'rm -rf "$body"' EXIT

{
  echo "The release for upstream \`${tag}\` failed: nothing was published, and the"
  echo "previous release stays current."
  echo
  echo "Run: ${run_url}"
  echo
  gh api --paginate "repos/${repo}/actions/runs/${run_id}/jobs" \
    --jq '.jobs[] | select(.conclusion == "failure") | [.id, .name, ([.steps[] | select(.conclusion == "failure") | .name] | join(", "))] | @tsv' |
    while IFS=$'\t' read -r job_id job_name steps; do
      echo "### ${job_name}"
      echo
      echo "Failed step: ${steps:-unknown}"
      echo
      echo "<details><summary>Log up to the first error</summary>"
      echo
      echo '```'
      # Drop timestamps; keep the 80 lines that end at the first error.
      gh api "repos/${repo}/actions/jobs/${job_id}/logs" 2>/dev/null |
        sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' |
        awk '{ lines[NR] = $0 } /^##\[error\]/ && !end { end = NR } END {
          if (!end) end = NR
          for (i = (end > 80 ? end - 79 : 1); i <= end; i++) print lines[i]
        }' || echo "(log not available)"
      echo '```'
      echo
      echo "</details>"
      echo
    done
  echo "While this issue is open, the scheduled check does not retry \`${tag}\`."
  echo "Fix the cause (usually: rebase the patch series named above on \`${tag}\`),"
  echo "then close this issue or run the release workflow manually."
} >"$body"

existing="$(gh issue list --repo "$repo" --state open --label release-failure \
  --search "\"${tag}\" in:title" --json number --jq '.[0].number // empty')"
if [[ -n "$existing" ]]; then
  gh issue comment "$existing" --repo "$repo" --body-file "$body"
  log "Commented on issue #${existing}"
else
  gh label create release-failure --repo "$repo" --color B60205 \
    --description "A release run failed; blocks scheduled retries while open" 2>/dev/null || true
  gh issue create --repo "$repo" --title "$title" --label release-failure --body-file "$body"
fi
