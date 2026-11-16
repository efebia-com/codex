#!/usr/bin/env bash
# Turn a built package directory into a release archive with its checksum.
#
# Usage: scripts/package.sh --package <dir> --source <dir> --version <version>
#                           --target <triple> --out-dir <dir>
#
# Adds to the package, as Apache-2.0 requires for modified redistributions:
#   LICENSE, NOTICE      upstream's, unchanged
#   MODIFICATIONS.md     what was changed: every patch, its subject and files
#   patches/             the patch series themselves
# and also DISTRIBUTION (version metadata read by install.sh) and install.sh
# (used for updates). Writes <out-dir>/codex-<target>.tar.gz and a .sha256 file.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git tar gzip

package=""
source_dir=""
version=""
target=""
out_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="${2:?}"; shift 2 ;;
    --source) source_dir="${2:?}"; shift 2 ;;
    --version) version="${2:?}"; shift 2 ;;
    --target) target="${2:?}"; shift 2 ;;
    --out-dir) out_dir="${2:?}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$package" && -n "$source_dir" && -n "$version" && -n "$target" && -n "$out_dir" ]] ||
  die "usage: $0 --package <dir> --source <dir> --version <version> --target <triple> --out-dir <dir>"
[[ -f "${package}/codex-package.json" ]] || die "not a Codex package directory: $package"

upstream_tag="$(git -C "$source_dir" config dist.upstreamTag)" ||
  die "$source_dir was not prepared by scripts/prepare-source.sh"
upstream_commit="$(git -C "$source_dir" rev-parse "refs/tags/${upstream_tag}^{commit}")"
source_commit="$(git -C "$source_dir" rev-parse HEAD)"
dist_commit="$(git -C "$DIST_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

cp "${source_dir}/LICENSE" "${source_dir}/NOTICE" "$package/"
cp "${DIST_ROOT}/install.sh" "$package/install.sh"
chmod 0755 "$package/install.sh"

cat >"${package}/DISTRIBUTION" <<EOF
version=${version}
upstream_tag=${upstream_tag}
upstream_commit=${upstream_commit}
target=${target}
source_commit=${source_commit}
distribution_commit=${dist_commit}
EOF

# Patches, in application order, and the summary of what they change.
rm -rf "${package}/patches"
mkdir -p "${package}/patches"
cp "${PATCHES_DIR}/series" "${package}/patches/series"
{
  echo "# Modifications"
  echo
  echo "This package is a modified version of OpenAI Codex ${upstream_tag}"
  echo "(https://github.com/${UPSTREAM_REPO}, commit ${upstream_commit}),"
  echo "licensed under the Apache License 2.0 (see LICENSE and NOTICE)."
  echo
  echo "The following patches were applied, in this order. The patch files are"
  echo "included in the patches/ directory of this package."
  mapfile -t extensions < <(series_extensions)
  if ((${#extensions[@]} == 0)); then
    echo
    echo "None: this build is unmodified upstream source."
  fi
  for extension in "${extensions[@]}"; do
    echo
    echo "## ${extension}"
    mkdir -p "${package}/patches/${extension}"
    while IFS= read -r patch; do
      cp "$patch" "${package}/patches/${extension}/"
      echo
      echo "- $(basename "$patch"): $(sed -n 's/^Subject: \(\[PATCH[^]]*\] \)\{0,1\}//p' "$patch" | head -n 1)"
      sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' "$patch" | LC_ALL=C sort -u | sed 's/^/  - /'
    done < <(extension_patches "$extension")
  done
  if git -C "$source_dir" diff --quiet "refs/tags/${upstream_tag}" HEAD -- codex-rs/Cargo.lock; then
    :
  else
    echo
    echo "## Build"
    echo
    echo "- codex-rs/Cargo.lock: updated for the workspace crates added by the patches;"
    echo "  external dependency versions are unchanged."
  fi
} >"${package}/MODIFICATIONS.md"

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
archive="${out_dir}/codex-${target}.tar.gz"
top="codex-${version}-${target}"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$package" "${staging}/${top}"
tar -C "$staging" -czf "$archive" "$top"
(cd "$out_dir" && printf '%s  %s\n' "$(sha256_file "$archive")" "$(basename "$archive")" >"$(basename "$archive").sha256")
log "Archive ready: ${archive}"
cat "${archive}.sha256"
