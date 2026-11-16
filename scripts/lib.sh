# shellcheck shell=bash
# Shared helpers for the distribution scripts. Source it; do not run it.

set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "error: bash 4 or newer is required (on macOS: brew install bash)" >&2
  exit 1
fi

DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPO="${UPSTREAM_REPO:-openai/codex}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
PATCHES_DIR="${PATCHES_DIR:-${DIST_ROOT}/patches}"
# libgit2 stalls on the large submodules of the rusty_v8 git dependency.
export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI:-true}"
# Stable tags only: rust-vX.Y.Z without a prerelease suffix.
STABLE_TAG_REGEX='^rust-v[0-9]+\.[0-9]+\.[0-9]+$'

log() {
  printf '==> %s\n' "$*" >&2
}

# Print an error (as a GitHub Actions annotation in CI) and exit.
die() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit 1
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
}

# GET a GitHub REST API path; uses GITHUB_TOKEN or GH_TOKEN when set.
github_api() {
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  local args=(-fsSL --retry 3 --retry-all-errors -H 'Accept: application/vnd.github+json')
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi
  curl "${args[@]}" "https://api.github.com/$1"
}

# Upstream version without the tag prefix: rust-v0.169.0 -> 0.169.0.
upstream_version() {
  [[ "$1" =~ $STABLE_TAG_REGEX ]] || die "not a stable upstream tag: $1"
  printf '%s\n' "${1#rust-v}"
}

# Non-comment, non-blank lines of a patches/ list file, first field only.
list_entries() {
  local file="$1"
  [[ -f "$file" ]] || die "missing file: $file"
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$file" | awk 'NF { print }'
}

# Extension directories in application order.
series_extensions() {
  list_entries "${PATCHES_DIR}/series"
}

# Patch files of one extension, in name order (git format-patch numbering).
extension_patches() {
  local dir="${PATCHES_DIR}/$1"
  [[ -d "$dir" ]] || die "patches/series lists '$1' but patches/$1/ does not exist"
  find "$dir" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort
}

# Upstream tag the patch series were generated against.
patches_base_tag() {
  list_entries "${PATCHES_DIR}/base" | head -n 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# Export RUSTY_V8_ARCHIVE and RUSTY_V8_SRC_BINDING_PATH for a target unless both
# are already set: Codex needs the Codex-built V8 (see fetch-v8.sh).
ensure_v8() {
  local source_dir="$1" target="$2" output line
  if [[ -n "${RUSTY_V8_ARCHIVE:-}" && -n "${RUSTY_V8_SRC_BINDING_PATH:-}" ]]; then
    return 0
  fi
  output="$("${DIST_ROOT}/scripts/fetch-v8.sh" --source "$source_dir" --target "$target")"
  while IFS= read -r line; do
    export "${line?}"
  done <<<"$output"
}

host_target() {
  rustc -vV | sed -n 's/^host: //p'
}
