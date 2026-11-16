#!/usr/bin/env bash
# Install a built archive with install.sh, as a user would, and smoke-test it.
#
# Usage: scripts/smoke.sh --archive-dir <dir> --version <version> [--skip-e2e]
#
# <dir> holds codex-<target>.tar.gz and its .sha256, as written by package.sh.
# The installer downloads them with curl from a file:// mirror laid out like
# GitHub release downloads, into a temporary prefix. Then the installed binary
# runs, and tests/e2e/run.sh runs against it. On macOS the script also reports
# what Gatekeeper sees: quarantine attribute, code signature, assessment, and
# whether a copy that carries the quarantine attribute still starts.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require curl tar

archive_dir=""
version=""
skip_e2e=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive-dir) archive_dir="${2:?}"; shift 2 ;;
    --version) version="${2:?}"; shift 2 ;;
    --skip-e2e) skip_e2e=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$archive_dir" && -n "$version" ]] || die "usage: $0 --archive-dir <dir> --version <version>"
archive_dir="$(cd "$archive_dir" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mirror="${work}/mirror/download/v${version}"
mkdir -p "$mirror"
cp "$archive_dir"/codex-*.tar.gz "$mirror/"
cat "$archive_dir"/codex-*.tar.gz.sha256 >"${mirror}/SHA256SUMS"

prefix="${work}/prefix"
log "Installing ${version} with install.sh into ${prefix}"
CODEX_EXT_DOWNLOAD_BASE="file://${work}/mirror" sh "${DIST_ROOT}/install.sh" --prefix "$prefix" --version "$version"
codex="${prefix}/bin/codex"
"$codex" --version
grep -q "^version=${version}$" "${prefix}/current/DISTRIBUTION" || die "installed DISTRIBUTION does not report ${version}"

if [[ "$(uname -s)" == Darwin ]]; then
  binary="$(cd "${prefix}/current/bin" && pwd)/codex"
  echo "--- Gatekeeper report ---"
  echo "spctl status: $(spctl --status 2>&1 || true)"
  echo "quarantine attribute after install: $(xattr -p com.apple.quarantine "$binary" 2>/dev/null || echo none)"
  echo "code signature:"
  codesign -dv "$binary" 2>&1 | sed 's/^/  /' || true
  echo "assessment (spctl -a -t exec):"
  spctl -a -t exec -vv "$binary" 2>&1 | sed 's/^/  /' || true
  # The case of a browser download: same binary, quarantine attribute set.
  quarantined="${work}/quarantined/codex"
  mkdir -p "${work}/quarantined"
  cp "$binary" "$quarantined"
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$quarantined"
  if "$quarantined" --version >/dev/null 2>&1; then
    echo "with quarantine attribute: starts"
  else
    echo "with quarantine attribute: blocked or failed (exit $?)"
  fi
  echo "-------------------------"
fi

e2e="${DIST_ROOT}/tests/e2e/run.sh"
if [[ "$skip_e2e" == true ]]; then
  log "Skipping tests/e2e (--skip-e2e)"
elif [[ -f "$e2e" ]]; then
  log "Running tests/e2e against ${codex}"
  bash "$e2e" "$codex"
else
  die "tests/e2e/run.sh is missing"
fi
