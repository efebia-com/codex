#!/usr/bin/env bash
# Open (or comment on) the release-failure issue for a failed release run.
#
# Usage: scripts/report-failure.sh <owner/repo> <run-id> <upstream-tag>
#        scripts/report-failure.sh --log <file> [--built-on <host>] <owner/repo> <upstream-tag>
#
# For a run of the release workflow, the issue names the failed jobs and steps
# and quotes the end of their logs, up to the first error. For a run of
# release-local.sh, --log is its output: the issue names the failed step and
# quotes the end of the log; --built-on names the machine it ran on (default:
# hostname -s). While the issue is open, scheduled runs skip this upstream tag
# (see check-release.sh); closing it allows the next attempt.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq

usage="usage: $0 <owner/repo> <run-id> <upstream-tag>
       $0 --log <file> [--built-on <host>] <owner/repo> <upstream-tag>"
local_log=""
built_on=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --log) local_log="${2:?}"; shift 2 ;;
    --built-on) built_on="${2:?}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
if [[ -n "$local_log" ]]; then
  [[ $# -eq 2 ]] || die "$usage"
  [[ -f "$local_log" ]] || die "no such log: $local_log"
  repo="$1"
  tag="$2"
  built_on="${built_on:-$(hostname -s)}"
else
  [[ $# -eq 3 && -z "$built_on" ]] || die "$usage"
  repo="$1"
  run_id="$2"
  tag="$3"
fi
title="Release failed: upstream ${tag}"

body="$(mktemp)"
trap 'rm -rf "$body"' EXIT

# The failed jobs of a workflow run, each with its log up to the first error.
workflow_failures() {
  echo "Run: https://github.com/${repo}/actions/runs/${run_id}"
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
}

# The failed step of a release-local.sh run, with the end of its log: the run
# stops at the first error, and its summary comes last.
local_failure() {
  local step
  step="$(sed -n 's/^  FAILED in \([^ ]*\) .*/\1/p' "$local_log" | tail -n 1)"
  echo "Built on ${built_on} by \`scripts/release-local.sh\`, log \`${local_log}\`."
  echo
  echo "Failed step: ${step:-unknown}"
  echo
  echo "<details><summary>End of the log</summary>"
  echo
  echo '```'
  tail -n 80 "$local_log"
  echo '```'
  echo
  echo "</details>"
  echo
}

{
  echo "The release for upstream \`${tag}\` failed: nothing was published, and the"
  echo "previous release stays current."
  echo
  if [[ -n "$local_log" ]]; then
    local_failure
  else
    workflow_failures
  fi
  echo "While this issue is open, the scheduled check does not retry \`${tag}\`."
  echo "Fix the cause (usually: rebase on \`${tag}\` the patch series that the log"
  echo "names), then close this issue or start the release by hand."
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
