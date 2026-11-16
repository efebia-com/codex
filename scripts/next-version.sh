#!/usr/bin/env bash
# Print the next distribution version for an upstream tag: <upstream>-ext.<N>.
#
# Usage: scripts/next-version.sh <upstream-tag> <owner/repo>
#
# N starts at 1 for every upstream version and grows by one each time the same
# upstream version is published again (for example with updated patches). The
# release tag is v<version>, e.g. v0.169.0-ext.1.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git

[[ $# -eq 2 ]] || die "usage: $0 <upstream-tag> <owner/repo>"
version="$(upstream_version "$1")"
repo="$2"

last="$(
  git ls-remote --tags "https://github.com/${repo}.git" "refs/tags/v${version}-ext.*" |
    sed -n "s|.*refs/tags/v${version//./\\.}-ext\\.\\([0-9][0-9]*\\)\$|\\1|p" |
    sort -n | tail -n 1
)"
printf '%s-ext.%s\n' "$version" "$((${last:-0} + 1))"
