#!/usr/bin/env bash
# Build a Codex package directory from a prepared source tree.
#
# Usage: scripts/build.sh --source <dir> --out <package-dir> [--release --target <triple>]
#                         [--prebuilt <dir>]
#
# Default (local) mode builds the host target with the dev profile, without
# --target, so it shares CARGO_TARGET_DIR with ordinary `cargo build` runs.
# With --prebuilt, it skips cargo and packages codex, codex-code-mode-host,
# codex-exec-server (and bwrap on Linux) already built in <dir>.
#
# Release mode (CI) follows upstream's release workflow: on Linux, bwrap is
# built and stripped first and its SHA-256 is embedded in Codex through
# CODEX_BWRAP_SHA256; then upstream's package builder compiles codex,
# codex-code-mode-host and codex-exec-server with the release profile and the
# Codex-built V8 (fetch-v8.sh), strips them and lays out the package. Linux musl
# targets need the toolchain set up by upstream's
# .github/scripts/install-musl-build-tools.sh.
#
# The package layout is upstream's: bin/, codex-resources/, codex-path/ and
# codex-package.json, which Codex uses to find its bundled helpers.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require cargo python3

source_dir=""
out=""
target=""
release=false
prebuilt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_dir="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --target) target="${2:?}"; shift 2 ;;
    --release) release=true; shift ;;
    --prebuilt) prebuilt="${2:?}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$source_dir" && -n "$out" ]] || die "usage: $0 --source <dir> --out <package-dir> [--release --target <triple>] [--prebuilt <dir>]"
[[ -z "$prebuilt" || "$release" == false ]] || die "--prebuilt is for local builds only"
source_dir="$(cd "$source_dir" && pwd)"
codex_rs="${source_dir}/codex-rs"
[[ -f "${codex_rs}/Cargo.toml" ]] || die "not a Codex source tree: $source_dir"

STABLE_GIT_COMMIT="$(git -C "$source_dir" rev-parse HEAD)"
# Upstream's package builder locates the source tree through CODEX_REPO_ROOT.
CODEX_REPO_ROOT="$source_dir"
export STABLE_GIT_COMMIT CODEX_REPO_ROOT

target_dir="${CARGO_TARGET_DIR:-${codex_rs}/target}"
package_builder=(python3 "${source_dir}/scripts/build_codex_package.py" --package-dir "$out" --force)

if [[ "$release" == true ]]; then
  [[ -n "$target" ]] || die "--release needs --target"
  release_dir="${target_dir}/${target}/release"
  ensure_v8 "$source_dir" "$target"
  args=(--target "$target" --cargo-profile release)
  if [[ "$target" == *-linux-* ]]; then
    log "Building bwrap for ${target}"
    (cd "$codex_rs" && cargo build --target "$target" --release --bin bwrap)
    bwrap="${release_dir}/bwrap"
    # Strip before hashing: the digest covers the exact packaged bytes.
    strip --strip-debug --strip-unneeded "$bwrap"
    CODEX_BWRAP_SHA256="$(sha256_file "$bwrap")"
    export CODEX_BWRAP_SHA256
    log "bwrap sha256:${CODEX_BWRAP_SHA256}"
    args+=(--bwrap-bin "$bwrap")
  fi
  log "Building Codex for ${target} (release)"
  (cd "$codex_rs" && "${package_builder[@]}" "${args[@]}")
else
  host="$(cd "$codex_rs" && host_target)"
  [[ -z "$target" || "$target" == "$host" ]] || die "local builds only support the host target ($host)"
  if [[ -n "$prebuilt" ]]; then
    debug_dir="$(cd "$prebuilt" && pwd)"
    log "Packaging binaries from ${debug_dir}"
  else
    ensure_v8 "$source_dir" "$host"
    debug_dir="${target_dir}/debug"
    bins=(--bin codex --bin codex-code-mode-host --bin codex-exec-server)
    [[ "$host" == *-linux-* ]] && bins+=(--bin bwrap)
    log "Building Codex for ${host} (dev profile)"
    (cd "$codex_rs" && cargo build "${bins[@]}")
  fi
  args=(
    --target "$host"
    --cargo-profile dev
    --strip none
    --entrypoint-bin "${debug_dir}/codex"
    --code-mode-host-bin "${debug_dir}/codex-code-mode-host"
    --exec-server-bin "${debug_dir}/codex-exec-server"
  )
  [[ "$host" == *-linux-* ]] && args+=(--bwrap-bin "${debug_dir}/bwrap")
  if command -v rg >/dev/null 2>&1; then
    args+=(--rg-bin "$(command -v rg)")
  fi
  (cd "$codex_rs" && "${package_builder[@]}" "${args[@]}")
fi

log "Package ready: ${out}"
