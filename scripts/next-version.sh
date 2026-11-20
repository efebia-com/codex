#!/usr/bin/env bash
# Print the next distribution version for an upstream tag.
#
# Usage: scripts/next-version.sh <upstream-tag> <owner/repo>
#
# The first release is <upstream>-efebia. Forced republishes append .2, .3, ...

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git

[[ $# -eq 2 ]] || die "usage: $0 <upstream-tag> <owner/repo>"
version="$(upstream_version "$1")"
repo="$2"

tag="refs/tags/v${version}-efebia"
last="$(
  git ls-remote --refs --tags "https://github.com/${repo}.git" "$tag" "${tag}.*" |
    awk -v tag="$tag" '
      $2 == tag { print 1 }
      index($2, tag ".") == 1 {
        revision = substr($2, length(tag) + 2)
        if (revision ~ /^[1-9][0-9]*$/) print revision
      }
    ' | sort -n | tail -n 1
)"
if [[ -z "$last" ]]; then
  printf '%s-efebia\n' "$version"
else
  printf '%s-efebia.%s\n' "$version" "$((last + 1))"
fi
