#!/usr/bin/env bash
# Publish a GitHub release from the archives built by the release workflow.
#
# Usage: scripts/publish.sh <owner/repo> <version> <upstream-tag> <assets-dir> <commit>
#
# <assets-dir> holds codex-<target>.tar.gz and .sha256 files for every target.
# Creates tag v<version> on <commit>, uploads the archives, SHA256SUMS and
# install.sh, and closes the release-failure issues of this upstream tag.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh tar

[[ $# -eq 5 ]] || die "usage: $0 <owner/repo> <version> <upstream-tag> <assets-dir> <commit>"
repo="$1"
version="$2"
tag="$3"
assets="$(cd "$4" && pwd)"
commit="$5"
release_tag="v${version}"

shopt -s nullglob
archives=("$assets"/codex-*.tar.gz)
((${#archives[@]} > 0)) || die "no archives in $assets"

cp "${DIST_ROOT}/install.sh" "${assets}/install.sh"
(
  cd "$assets"
  cat codex-*.tar.gz.sha256
  printf '%s  %s\n' "$(sha256_file install.sh)" install.sh
) | LC_ALL=C sort -k 2 >"${assets}/SHA256SUMS"

first="$(basename "${archives[0]}" .tar.gz)"
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
{
  echo "Codex ${version}: upstream [${tag}](https://github.com/${UPSTREAM_REPO}/releases/tag/${tag}) with the extensions below."
  echo
  echo "Install or update (Linux and macOS):"
  echo
  echo '```sh'
  echo "curl -fsSL https://github.com/${repo}/releases/latest/download/install.sh | sh"
  echo '```'
  echo
  tar -xzOf "${archives[0]}" "codex-${version}-${first#codex-}/MODIFICATIONS.md" |
    sed -e 's/^## /### /' -e 's/^# Modifications$/## Modifications/'
  echo
  echo "## Checksums (SHA-256)"
  echo
  echo '```'
  cat "${assets}/SHA256SUMS"
  echo '```'
} >"$notes"

# Mark as latest only if no newer distribution version is already out.
latest_flag=(--latest)
current_latest="$(gh release view --repo "$repo" --json tagName --jq .tagName 2>/dev/null || true)"
if [[ -n "$current_latest" ]] &&
  [[ "$(printf '%s\n%s\n' "${current_latest#v}" "$version" | sort -V | tail -n 1)" != "$version" ]]; then
  latest_flag=(--latest=false)
fi

gh release create "$release_tag" --repo "$repo" --target "$commit" \
  --title "Codex ${version}" --notes-file "$notes" "${latest_flag[@]}" \
  "${archives[@]}" "${assets}/SHA256SUMS" "${assets}/install.sh"
log "Published ${release_tag}"

gh issue list --repo "$repo" --state open --label release-failure \
  --search "\"${tag}\" in:title" --json number --jq '.[].number' |
  while read -r number; do
    gh issue close "$number" --repo "$repo" \
      --comment "Published ${release_tag}: https://github.com/${repo}/releases/tag/${release_tag}"
  done
