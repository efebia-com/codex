#!/usr/bin/env bash
# Download and verify the Codex-built V8 for a target, as upstream's release does.
#
# Usage: scripts/fetch-v8.sh --source <dir> --target <triple> [--cache <dir>]
#
# Codex links V8 with the `ptrcomp_sandbox_release` profile, which only exists
# as release assets of openai/codex (rusty-v8-v<version>). This uses upstream's
# own implementation from the prepared source (scripts/codex_package/v8.py):
# the V8 version comes from the source's Cargo.lock, the per-target checksum
# manifest is checked against third_party/v8/rusty_v8_<version>_release_manifests.sha256
# in the source, and both artifacts are checked against that manifest.
#
# Prints RUSTY_V8_ARCHIVE=... and RUSTY_V8_SRC_BINDING_PATH=... for $GITHUB_ENV
# or for `export`.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require python3

source_dir=""
target=""
cache=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_dir="${2:?}"; shift 2 ;;
    --target) target="${2:?}"; shift 2 ;;
    --cache) cache="${2:?}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$source_dir" && -n "$target" ]] || die "usage: $0 --source <dir> --target <triple> [--cache <dir>]"
source_dir="$(cd "$source_dir" && pwd)"
[[ -f "${source_dir}/scripts/codex_package/v8.py" ]] || die "no scripts/codex_package/v8.py in $source_dir"

# Upstream's package modules locate the source tree through CODEX_REPO_ROOT.
CODEX_REPO_ROOT="$source_dir" python3 -I - "${source_dir}/scripts" "$target" "$cache" <<'PY'
import sys
from pathlib import Path

scripts, target, cache = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, scripts)
from codex_package import v8  # noqa: E402
from codex_package.targets import TARGET_SPECS  # noqa: E402

version = v8.resolved_v8_crate_version()
print(f"V8 {version} for {target}", file=sys.stderr)
pair = v8.fetch_codex_v8_artifacts(
    TARGET_SPECS[target], cache_root=Path(cache) if cache else None
)
print(f"RUSTY_V8_ARCHIVE={pair.archive}")
print(f"RUSTY_V8_SRC_BINDING_PATH={pair.binding}")
PY
