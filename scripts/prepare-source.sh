#!/usr/bin/env bash
# Fetch an upstream tag and apply the patch series in patches/series.
#
# Usage: scripts/prepare-source.sh [--force] [--skip-lock] <upstream-tag> <dest-dir>
#
#   --force      replace <dest-dir> if it exists
#   --skip-lock  only check that the patches apply; leave Cargo.lock as it is.
#                Updating it resolves every dependency, which fetches the git
#                dependencies (several hundred MB); build jobs do that anyway.
#
# The result is a git checkout on branch `dist`: the upstream tag, one commit
# per patch, and, when the patches add workspace crates, one commit updating
# Cargo.lock. Commits are deterministic (fixed committer and date), so every CI
# job that prepares the same inputs gets the same tree and commit ids.
#
# Fails at the first patch that does not apply, naming the extension, the patch
# and the conflicting files.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git awk

force=false
skip_lock=false
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --force) force=true ;;
    --skip-lock) skip_lock=true ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ $# -eq 2 ]] || die "usage: $0 [--force] [--skip-lock] <upstream-tag> <dest-dir>"
tag="$1"
dest="$2"
upstream_version "$tag" >/dev/null

if [[ -e "$dest" ]]; then
  [[ "$force" == true ]] || die "$dest already exists (pass --force to replace it)"
  rm -rf "$dest"
fi

mapfile -t extensions < <(series_extensions)
base_tag="$(patches_base_tag)"

git_dest() {
  git -C "$dest" "$@"
}

log "Fetching ${tag} from ${UPSTREAM_URL}"
git init -q "$dest"
git_dest fetch -q --depth 1 "$UPSTREAM_URL" "refs/tags/${tag}:refs/tags/${tag}"
# The base tree lets `git am --3way` merge patches whose context moved upstream.
if ((${#extensions[@]} > 0)) && [[ "$base_tag" != "$tag" ]]; then
  log "Fetching patch base ${base_tag}"
  git_dest fetch -q --depth 1 "$UPSTREAM_URL" "refs/tags/${base_tag}:refs/tags/${base_tag}"
fi
git_dest checkout -q -b dist "refs/tags/${tag}^{commit}"
git_dest config dist.upstreamTag "$tag"

# Deterministic commits: same inputs, same commit ids in every job.
GIT_COMMITTER_NAME="Codex distribution build"
GIT_COMMITTER_EMAIL="build@localhost"
GIT_COMMITTER_DATE="$(git_dest log -1 --format=%cI HEAD)"
export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

indent() {
  local line
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done
}

report_failure() {
  local extension="$1" patch="$2" output="$3"
  local subject conflicts
  subject="$(sed -n 's/^Subject: //p' "$patch" | head -n 1)"
  conflicts="$(git_dest diff --name-only --diff-filter=U 2>/dev/null || true)"
  {
    echo
    echo "Patch does not apply"
    echo "  upstream:  ${tag} (series generated on ${base_tag})"
    echo "  extension: ${extension}"
    echo "  patch:     patches/${extension}/$(basename "$patch")"
    echo "  subject:   ${subject}"
    if [[ -n "$conflicts" ]]; then
      echo "  conflicts:"
      indent <<<"$conflicts"
    fi
    echo "  git am output:"
    indent <<<"$output"
    echo
    echo "Rebase patches/${extension}/ on ${tag}, regenerate it with git format-patch,"
    echo "then update patches/base if every series now targets ${tag}."
  } >&2
  git_dest am --abort >/dev/null 2>&1 || true
  die "patches/${extension}/$(basename "$patch") does not apply on ${tag}"
}

applied=0
for extension in "${extensions[@]}"; do
  mapfile -t patches < <(extension_patches "$extension")
  ((${#patches[@]} > 0)) || die "patches/${extension}/ has no *.patch files"
  log "Applying ${extension} (${#patches[@]} patches)"
  for patch in "${patches[@]}"; do
    if ! output="$(git_dest am --3way --quiet "$patch" 2>&1)"; then
      report_failure "$extension" "$patch" "$output"
    fi
    applied=$((applied + 1))
  done
done
log "Applied ${applied} patches on ${tag}"

# Packages that do not belong to the workspace: name, version and source.
external_packages() {
  awk '
    /^\[\[package\]\]/ { if (src != "") print name, ver, src; name = ver = src = ""; next }
    /^name = / { name = $3 }
    /^version = / { ver = $3 }
    /^source = / { src = $3 }
    END { if (src != "") print name, ver, src }
  ' "$1" | LC_ALL=C sort
}

# Patches leave Cargo.lock out: it would conflict on almost every release.
# Record new workspace crates without moving any other dependency.
if [[ "$skip_lock" == false ]] && ! git_dest diff --quiet "refs/tags/${tag}" HEAD -- '*Cargo.toml'; then
  require cargo
  lock="${dest}/codex-rs/Cargo.lock"
  before="$(external_packages "$lock")"
  log "Updating Cargo.lock for workspace changes"
  (cd "${dest}/codex-rs" && cargo update --workspace --quiet)
  after="$(external_packages "$lock")"
  if [[ "$before" != "$after" ]]; then
    echo "External dependencies changed in Cargo.lock (- before, + after):" >&2
    diff <(echo "$before") <(echo "$after") | grep '^[<>]' | sed 's/^</-/; s/^>/+/' >&2 || true
    die "patches must only use dependencies already locked by ${tag}"
  fi
  if ! git_dest diff --quiet -- codex-rs/Cargo.lock; then
    git_dest -c user.name="$GIT_COMMITTER_NAME" -c user.email="$GIT_COMMITTER_EMAIL" \
      commit -q --date="$GIT_COMMITTER_DATE" -m "Update Cargo.lock for distribution patches" \
      -- codex-rs/Cargo.lock
  fi
fi

log "Source ready: ${dest} ($(git_dest rev-parse --short HEAD))"
