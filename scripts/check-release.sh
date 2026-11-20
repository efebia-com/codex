#!/usr/bin/env bash
# Decide whether to build a release, and which one.
#
# Usage: scripts/check-release.sh <owner/repo> [--tag <upstream-tag>] [--force] [--scheduled]
#
#   --tag        upstream tag to build (default: the newest stable upstream release)
#   --force      build even if this upstream version is already published; used
#                to publish a new revision with updated patches
#   --scheduled  automatic run: skip while a release-failure issue for this
#                upstream tag is open, so a broken build does not rerun every
#                30 minutes; closing the issue allows the next attempt
#
# Prints key=value lines (build, upstream_tag, version, reason), suitable for
# $GITHUB_OUTPUT.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git

[[ $# -ge 1 ]] || die "usage: $0 <owner/repo> [--tag <upstream-tag>] [--force] [--scheduled]"
repo="$1"
shift
tag=""
force=false
scheduled=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:?}"; shift 2 ;;
    --force) force=true; shift ;;
    --scheduled) scheduled=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

scripts="$(dirname "${BASH_SOURCE[0]}")"
[[ -n "$tag" ]] || tag="$("${scripts}/upstream-latest.sh")"
upstream="$(upstream_version "$tag")"

emit() {
  printf 'build=%s\nupstream_tag=%s\nversion=%s\nreason=%s\n' "$1" "$tag" "${2:-}" "$3"
}

published="$(git ls-remote --refs --tags "https://github.com/${repo}.git" \
  "refs/tags/v${upstream}-efebia" "refs/tags/v${upstream}-efebia.*" "refs/tags/v${upstream}-ext.*")"
if [[ -n "$published" && "$force" == false ]]; then
  emit false "" "${tag} is already published"
  exit 0
fi

if [[ "$scheduled" == true ]]; then
  require gh
  open_issues="$(gh issue list --repo "$repo" --state open --label release-failure \
    --search "\"${tag}\" in:title" --json number --jq length)"
  if ((open_issues > 0)); then
    emit false "" "a release-failure issue for ${tag} is open; close it to retry"
    exit 0
  fi
fi

emit true "$("${scripts}/next-version.sh" "$tag" "$repo")" "building ${tag}"
