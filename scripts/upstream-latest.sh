#!/usr/bin/env bash
# Print the newest stable upstream release tag (rust-vX.Y.Z): a published
# GitHub release that is neither a draft nor a prerelease.
#
# Usage: scripts/upstream-latest.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require curl jq

# Releases come newest first; alphas of the next versions can fill a page.
for page in 1 2 3 4; do
  tag="$(
    github_api "repos/${UPSTREAM_REPO}/releases?per_page=50&page=${page}" |
      jq -r --arg re "$STABLE_TAG_REGEX" '
        [.[] | select((.draft | not) and (.prerelease | not)) | .tag_name | select(test($re))]
        | sort_by(ltrimstr("rust-v") | split(".") | map(tonumber))
        | last // empty'
  )"
  if [[ -n "$tag" ]]; then
    printf '%s\n' "$tag"
    exit 0
  fi
done
die "no stable release found in the newest 200 releases of ${UPSTREAM_REPO}"
