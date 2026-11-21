#!/usr/bin/env bash
# Scheduled release on a build machine: run it from a timer every 30 minutes,
# from a clean clone of <owner/repo> that it keeps at the tip of main.
#
# Usage: scripts/release-scheduled.sh [options] <owner/repo>
#
#   --work <dir>        as for release-local.sh (default: .work/release-local in this checkout)
#   --lock <file>       as for release-local.sh (default: <work>/lock); this script waits for it
#   --jobs <n>          passed to release-local.sh
#   --release-jobs <n>  passed to release-local.sh
#   --built-on <name>   passed to release-local.sh, and named in a failure issue
#                       (default: hostname -s)
#
# Every run checks, with check-release.sh --scheduled, for a stable upstream
# release that is not published yet and has no open release-failure issue. When
# there is one, it waits for the lock, fast-forwards the clone to main of
# <owner/repo>, checks again and runs release-local.sh for that upstream tag,
# with its output in <work>/logs. If that run fails, report-failure.sh opens or
# updates the release-failure issue with the end of the log: the next checks
# skip that upstream release until the issue is closed. While a release.yml run
# is queued or in progress nothing starts, and the next check tries again.
#
# Exit status: 0 when there is nothing to build, when the release is published,
# or when the next check tries again; otherwise that of the failure.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git gh flock

usage="usage: $0 [--work <dir>] [--lock <file>] [--jobs <n>] [--release-jobs <n>] [--built-on <name>] <owner/repo>"

args=("$@")
work="${DIST_ROOT}/.work/release-local"
lock=""
built_on="$(hostname -s)"
release_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) work="${2:?}"; shift 2 ;;
    --lock) lock="${2:?}"; shift 2 ;;
    --built-on) built_on="${2:?}"; shift 2 ;;
    --jobs | --release-jobs) release_args+=("$1" "${2:?}"); shift 2 ;;
    --tag | --force | --dry-run) die "$1 is for releases by hand, with release-local.sh" ;;
    --*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[[ $# -eq 1 && "$1" == */* ]] || die "$usage"
repo="$1"

mkdir -p "$work"
work="$(cd "$work" && pwd)"
lock="${lock:-${work}/lock}"
# The same lock, by the same name: release-local.sh then runs under this one.
release_args+=(--work "$work" --lock "$lock" --built-on "$built_on")

# Sets build, tag and reason from check-release.sh --scheduled.
check() {
  local plan
  plan="$("${DIST_ROOT}/scripts/check-release.sh" "$repo" --scheduled)" ||
    die "the release check failed"
  build="$(sed -n 's/^build=//p' <<<"$plan")"
  tag="$(sed -n 's/^upstream_tag=//p' <<<"$plan")"
  reason="$(sed -n 's/^reason=//p' <<<"$plan")"
}

if [[ "${RELEASE_LOCAL_LOCK:-}" != "$lock" ]]; then
  # A check with nothing to build does not wait for the lock.
  check
  if [[ "$build" != true ]]; then
    log "Nothing to build: ${reason}"
    exit 0
  fi
  log "To build: ${tag}. Waiting for ${lock}"
  # As in release-local.sh: -o, processes that the tests leave running do not
  # inherit the lock.
  RELEASE_LOCAL_LOCK="$lock" exec flock -o "$lock" "$BASH" "${BASH_SOURCE[0]}" "${args[@]}"
fi

# Under the lock no other release run uses the clone: bring it to main.
[[ -z "$(git -C "$DIST_ROOT" status --porcelain)" ]] ||
  die "the checkout ${DIST_ROOT} has local changes"
git -C "$DIST_ROOT" fetch --quiet "https://github.com/${repo}.git" main
main="$(git -C "$DIST_ROOT" rev-parse FETCH_HEAD)"
git -C "$DIST_ROOT" merge --ff-only --quiet "$main" &&
  [[ "$(git -C "$DIST_ROOT" rev-parse HEAD)" == "$main" ]] ||
  die "the checkout ${DIST_ROOT} has commits that are not on main of ${repo}"
log "Checkout at $(git -C "$DIST_ROOT" log -1 --format='%h %s')"

# The release may have been published, or may have failed, while this run waited.
check
if [[ "$build" != true ]]; then
  log "Nothing to build: ${reason}"
  exit 0
fi
active="$(gh run list --repo "$repo" --workflow release.yml --limit 50 --json status \
  --jq '[.[] | select(.status != "completed")] | length')"
if ((active > 0)); then
  log "A release.yml run of ${repo} is queued or in progress: the next check tries again"
  exit 0
fi

mkdir -p "${work}/logs"
release_log="${work}/logs/release-$(date +%Y%m%d-%H%M%S)-${tag}.log"
log "Building ${tag} with release-local.sh, log ${release_log}"
rc=0
"${DIST_ROOT}/scripts/release-local.sh" "${release_args[@]}" --tag "$tag" "$repo" \
  >"$release_log" 2>&1 || rc=$?
sed -n '/^=== release-local summary/,$p' "$release_log" >&2
if ((rc == 0)); then
  log "Published the release of ${tag}"
  exit 0
fi
log "release-local.sh failed (exit ${rc}): reporting it"
"${DIST_ROOT}/scripts/report-failure.sh" --log "$release_log" --built-on "$built_on" "$repo" "$tag" ||
  log "could not open or update the release-failure issue"
exit "$rc"
