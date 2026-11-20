#!/usr/bin/env bash
# Build, test and publish a release on this machine instead of GitHub Actions,
# for x86_64-unknown-linux-musl, with the steps of .github/workflows/release.yml.
#
# Usage: scripts/release-local.sh [options] <owner/repo>
#
#   --tag <tag>         upstream tag to build (default: the newest stable upstream release)
#   --force             publish a new revision of an upstream version that is already
#                       published (as the workflow's force input)
#   --dry-run           run every step except the publication; the checkout may then
#                       have local changes or commits that are not on main (warnings)
#   --work <dir>        work directory (default: .work/release-local in this checkout)
#   --jobs <n>          cargo jobs for the extension tests (default: cargo's)
#   --release-jobs <n>  cargo jobs for the release build (default: 1; the largest crates
#                       need several GB of memory each)
#   --lock <file>       lock held for the whole run (default: <work>/lock)
#   --built-on <name>   host named in the release notes (default: hostname -s)
#
# Steps, as in release.yml:
#   plan     check-release.sh: the version (v<upstream>-efebia); an upstream version
#            that is already published is refused unless --force
#   prepare  prepare-source.sh into <work>/src
#   test     test-extensions.sh, with the Codex-built V8 for this host
#   build    upstream's .github/scripts/install-musl-build-tools.sh, fetch-v8.sh and
#            build.sh --release --target x86_64-unknown-linux-musl
#   package  package.sh into <work>/dist
#   smoke    smoke.sh: install.sh from a file:// mirror, then tests/e2e
#   publish  publish.sh on the checked-out commit, with "built on <name>" in the notes
#
# The checkout must be clean and at the tip of main of <owner/repo>: that commit is
# the release tag's target and is recorded in every package. Nothing starts while a
# release.yml run of <owner/repo> is queued or running, or while another run holds
# the lock; right before publishing, the runs and the version are checked again, so
# a release that the workflow published meanwhile is not published twice.
#
# Cargo steps run with CARGO_INCREMENTAL=0, each in an emptied target directory,
# with a Cargo home that has no configuration (it keeps downloaded crates between
# runs) and without the build variables of the calling shell, as on a fresh runner.
#
# Requirements: Linux x86_64 with bash 4, git, gh (logged in, allowed to create
# releases in <owner/repo>), curl, jq, python3, rustup, flock (util-linux), tar,
# xz, perl, make, gcc, g++, pkg-config, binutils, and the libcap development files
# for the tests. Nothing is installed with sudo: what install-musl-build-tools.sh
# would install with apt-get is taken from the system when present, otherwise
# provided under <work>/cache/tools: musl-gcc from the distribution's musl
# packages (apt-get download, Debian or Ubuntu), ld.lld from the Rust toolchain;
# zig is always 0.14.0, as release.yml installs it.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require git gh curl jq python3 rustup flock tar xz perl make gcc g++ pkg-config ar ranlib strip

usage="usage: $0 [--tag <tag>] [--force] [--dry-run] [--work <dir>] [--jobs <n>] [--release-jobs <n>] [--lock <file>] [--built-on <name>] <owner/repo>"
target=x86_64-unknown-linux-musl
host=x86_64-unknown-linux-gnu
zig_version=0.14.0
zig_sha256=473ec26806133cf4d1918caf1a410f8403a13d979726a9045b421b685031a982

args=("$@")
tag=""
force=false
dry_run=false
work="${DIST_ROOT}/.work/release-local"
test_jobs=""
release_jobs=1
lock=""
built_on="$(hostname -s)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:?}"; shift 2 ;;
    --force) force=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    --work) work="${2:?}"; shift 2 ;;
    --jobs) test_jobs="${2:?}"; shift 2 ;;
    --release-jobs) release_jobs="${2:?}"; shift 2 ;;
    --lock) lock="${2:?}"; shift 2 ;;
    --built-on) built_on="${2:?}"; shift 2 ;;
    --*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[[ $# -eq 1 ]] || die "$usage"
repo="$1"
[[ "$repo" == */* ]] || die "$usage"
[[ -z "$test_jobs" || "$test_jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive number"
[[ "$release_jobs" =~ ^[1-9][0-9]*$ ]] || die "--release-jobs needs a positive number"
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || die "this script builds ${target} on Linux x86_64 only"

mkdir -p "$work"
work="$(cd "$work" && pwd)"
[[ "$work" != *[[:space:]\|]* ]] || die "the work directory path must not contain spaces or '|': $work"
lock="${lock:-${work}/lock}"

# Hold the lock in a flock process around the whole run. -o: processes that the
# tests leave running do not inherit it.
if [[ "${RELEASE_LOCAL_LOCK:-}" != "$lock" ]]; then
  rc=0
  RELEASE_LOCAL_LOCK="$lock" flock -n -o -E 75 "$lock" "$BASH" "${BASH_SOURCE[0]}" "${args[@]}" || rc=$?
  ((rc != 75)) || die "another run holds ${lock}"
  exit "$rc"
fi

cache="${work}/cache"
tools="${cache}/tools"
src="${work}/src"
dist="${work}/dist"

# A fresh runner has none of these; inherited, they would change what is built.
unset CARGO_TARGET_DIR CARGO_BUILD_TARGET CARGO_BUILD_JOBS CARGO_BUILD_RUSTFLAGS \
  RUSTFLAGS CARGO_ENCODED_RUSTFLAGS RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTUP_TOOLCHAIN \
  CC CXX CFLAGS CXXFLAGS LDFLAGS RUSTY_V8_ARCHIVE RUSTY_V8_SRC_BINDING_PATH \
  ZIG_GLOBAL_CACHE_DIR GITHUB_ENV RUNNER_TEMP
export CARGO_INCREMENTAL=0
export CARGO_HOME="${cache}/cargo-home"
mkdir -p "$CARGO_HOME"
: >"${CARGO_HOME}/config.toml"

warn() {
  printf 'warning: %s\n' "$*" >&2
}

# Problems that block a publication; a dry run only reports them.
blocker() {
  if [[ "$dry_run" == true ]]; then
    warn "$* (would stop a real release)"
  else
    die "$*"
  fi
}

# Export KEY=VALUE lines, as GitHub Actions does with $GITHUB_ENV.
export_lines() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "not a KEY=VALUE line: $line"
    export "${line?}"
  done <<<"$1"
}

check_release_runs() {
  local active
  active="$(gh run list --repo "$repo" --workflow release.yml --limit 50 \
    --json databaseId,status,event \
    --jq '.[] | select(.status != "completed") | "\(.databaseId) (\(.event), \(.status))"')"
  [[ -z "$active" ]] || blocker "release.yml runs of ${repo} are queued or in progress: ${active//$'\n'/, }"
}

check_checkout() {
  local main
  [[ -z "$(git -C "$DIST_ROOT" status --porcelain)" ]] ||
    blocker "the checkout ${DIST_ROOT} has local changes"
  main="$(git ls-remote "https://github.com/${repo}.git" refs/heads/main | awk '{ print $1 }')"
  [[ -n "$main" ]] || die "cannot read main of ${repo}"
  [[ "$commit" == "$main" ]] ||
    blocker "the checkout is at ${commit:0:12}, not at the tip of ${repo} main (${main:0:12})"
}

steps=()
current=""
run_step() {
  local name="$1" start=$SECONDS
  shift
  current="$name"
  echo
  echo "=== ${name} ($(date '+%F %T'))"
  "$@"
  steps+=("$(printf '%-8s %4d min' "$name" $(((SECONDS - start + 30) / 60)))")
  current=""
}

report() {
  local rc=$? entry
  echo
  echo "=== release-local summary"
  for entry in "${steps[@]}"; do echo "  $entry"; done
  if ((rc != 0)); then
    echo "  FAILED in ${current:-setup} (exit ${rc})"
  fi
  echo "  total    $(((SECONDS + 30) / 60)) min"
}
trap report EXIT

step_plan() {
  local plan_args=("$repo") plan build reason
  [[ -n "$tag" ]] && plan_args+=(--tag "$tag")
  [[ "$force" == true ]] && plan_args+=(--force)
  plan="$("${DIST_ROOT}/scripts/check-release.sh" "${plan_args[@]}")"
  printf '%s\n' "$plan"
  build="$(sed -n 's/^build=//p' <<<"$plan")"
  reason="$(sed -n 's/^reason=//p' <<<"$plan")"
  [[ "$build" == true ]] || die "${reason}; --force publishes a new revision"
  tag="$(sed -n 's/^upstream_tag=//p' <<<"$plan")"
  version="$(sed -n 's/^version=//p' <<<"$plan")"
  log "Release v${version} of ${tag} from ${commit:0:12}, built on ${built_on}"
}

step_prepare() {
  local url toolchain channel
  # The toolchain pinned by the upstream tag, as the workflow's setup-rust.
  url="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${tag}/codex-rs/rust-toolchain.toml"
  toolchain="$(curl -fsSL --retry 3 "$url")"
  channel="$(sed -n 's/^channel = "\(.*\)"$/\1/p' <<<"$toolchain")"
  [[ -n "$channel" ]] || die "no toolchain channel in $url"
  # rustup refuses to run from a Cargo home other than the one it is installed in.
  env -u CARGO_HOME rustup toolchain install "$channel" --profile minimal --target "$target"
  "${DIST_ROOT}/scripts/prepare-source.sh" --force "$tag" "$src"
}

# The test and build steps run in subshells: their environments stay apart, as in
# separate jobs.
# shellcheck disable=SC2030
step_test() (
  local v8_env
  export CARGO_TARGET_DIR="${work}/target-test"
  rm -rf "$CARGO_TARGET_DIR"
  [[ -z "$test_jobs" ]] || export CARGO_BUILD_JOBS="$test_jobs"
  pkg-config --exists libcap ||
    die "libcap development files not found (libcap-dev; or point PKG_CONFIG_PATH at a libcap.pc)"
  v8_env="$("${DIST_ROOT}/scripts/fetch-v8.sh" --source "$src" --target "$host" --cache "${cache}/rusty_v8")"
  export_lines "$v8_env"
  "${DIST_ROOT}/scripts/test-extensions.sh" --source "$src"
)

# Make the packages that install-musl-build-tools.sh installs with apt-get
# available without root, through a directory put first in PATH.
provide_musl_tools() {
  local bin="${tools}/bin" musl="${tools}/musl" zig_dir="${tools}/zig-${zig_version}" rust_lld deb archive
  local multiarch=x86_64-linux-musl
  mkdir -p "$bin"

  # upstream's script runs `sudo apt-get update/install`: those packages are provided here.
  cat >"${bin}/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == apt-get ]]; then
  echo "release-local: skipped 'sudo $*': its packages are provided without root" >&2
  exit 0
fi
echo "release-local: sudo is not used: $*" >&2
exit 1
EOF
  chmod +x "${bin}/sudo"

  if command -v "${multiarch}-gcc" >/dev/null 2>&1 && [[ "$(command -v "${multiarch}-gcc")" != "${bin}/"* ]]; then
    log "musl-gcc: $(command -v "${multiarch}-gcc") (system)"
  else
    require apt-get dpkg-deb
    log "musl-gcc: extracting the distribution's musl packages into ${musl}"
    rm -rf "$musl"
    mkdir -p "${musl}/debs"
    # apt verifies the packages against the signed repository index.
    (cd "${musl}/debs" && apt-get download -q musl musl-dev musl-tools)
    for deb in "${musl}"/debs/*.deb; do
      dpkg-deb -x "$deb" "${musl}/root"
    done
    # The wrapper and its specs file name absolute paths; point them here. The
    # dynamic loader is for helpers that builds compile and run (libcap's
    # _makenames); the release binaries are static.
    # The loader goes last: its new path contains /usr/lib/<multiarch>.
    sed -i -e "s|/usr/lib/${multiarch}|${musl}/root/usr/lib/${multiarch}|g" \
      -e "s|/usr/include/${multiarch}|${musl}/root/usr/include/${multiarch}|g" \
      -e "s|/lib/ld-musl-x86_64.so.1|${musl}/root/usr/lib/${multiarch}/libc.so|g" \
      "${musl}/root/usr/bin/${multiarch}-gcc" "${musl}/root/usr/lib/${multiarch}/musl-gcc.specs"
    ln -sfn "${musl}/root/usr/bin/${multiarch}-gcc" "${bin}/${multiarch}-gcc"
    ln -sfn "${musl}/root/usr/bin/${multiarch}-gcc" "${bin}/musl-gcc"
    log "musl-gcc: ${musl}/root ($(cd "${musl}/debs" && echo *.deb))"
  fi

  if command -v ld.lld >/dev/null 2>&1 && [[ "$(command -v ld.lld)" != "${bin}/"* ]]; then
    log "ld.lld: $(command -v ld.lld) (system)"
  else
    rust_lld="$(cd "${src}/codex-rs" && rustc --print sysroot)/lib/rustlib/${host}/bin/rust-lld"
    [[ -x "$rust_lld" ]] || die "no ld.lld, and no rust-lld in the Rust toolchain ($rust_lld)"
    # lld picks its flavor from the name it is called by.
    ln -sfn "$rust_lld" "${bin}/ld.lld"
    log "ld.lld: ${rust_lld}"
  fi

  if [[ ! -x "${zig_dir}/zig" ]]; then
    archive="${tools}/zig-linux-x86_64-${zig_version}.tar.xz"
    log "zig: downloading ${zig_version}"
    curl -fsSL --retry 3 -o "$archive" "https://ziglang.org/download/${zig_version}/zig-linux-x86_64-${zig_version}.tar.xz"
    echo "${zig_sha256}  ${archive}" | sha256sum -c -
    rm -rf "$zig_dir"
    mkdir -p "$zig_dir"
    tar -xJf "$archive" -C "$zig_dir" --strip-components=1
    rm -f "$archive"
  fi
  ln -sfn "${zig_dir}/zig" "${bin}/zig"
  log "zig: $("${bin}/zig" version)"
  export PATH="${bin}:${PATH}"
}

# shellcheck disable=SC2031
step_build() (
  local runner_temp musl_env check v8_env
  export CARGO_TARGET_DIR="${work}/target-release"
  runner_temp="${work}/runner-temp"
  rm -rf "$CARGO_TARGET_DIR" "$runner_temp" "${work}/package"
  mkdir -p "$runner_temp"
  export CARGO_BUILD_JOBS="$release_jobs"
  export ZIG_GLOBAL_CACHE_DIR="${runner_temp}/zig-cache"

  provide_musl_tools
  check="${runner_temp}/musl-check"
  printf '#include <stdio.h>\nint main(void) { puts("musl-gcc ok"); return 0; }\n' >"${check}.c"
  # Static, as the release binaries; dynamic, as helpers that builds run.
  x86_64-linux-musl-gcc -static -o "${check}-static" "${check}.c"
  x86_64-linux-musl-gcc -o "${check}-dynamic" "${check}.c"
  "${check}-static"
  "${check}-dynamic"

  # As release.yml: upstream's script sets the musl toolchain through $GITHUB_ENV.
  musl_env="${runner_temp}/github-env"
  : >"$musl_env"
  TARGET="$target" GITHUB_ENV="$musl_env" RUNNER_TEMP="$runner_temp" CODEX_MUSL_RELEASE_LINK_FLAGS=1 \
    bash "${src}/.github/scripts/install-musl-build-tools.sh"
  echo "Environment from install-musl-build-tools.sh:"
  sed 's/^/  /' "$musl_env"
  export_lines "$(<"$musl_env")"
  export AWS_LC_SYS_NO_JITTER_ENTROPY=1 "AWS_LC_SYS_NO_JITTER_ENTROPY_${target//-/_}=1"

  v8_env="$("${DIST_ROOT}/scripts/fetch-v8.sh" --source "$src" --target "$target" --cache "${cache}/rusty_v8")"
  export_lines "$v8_env"
  log "Release build with CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}"
  CODEX_DISPLAY_VERSION="$version" \
    "${DIST_ROOT}/scripts/build.sh" --release --target "$target" --source "$src" --out "${work}/package"
)

step_package() {
  rm -rf "$dist"
  "${DIST_ROOT}/scripts/package.sh" --package "${work}/package" --source "$src" \
    --version "$version" --target "$target" --out-dir "$dist"
}

step_smoke() {
  "${DIST_ROOT}/scripts/smoke.sh" --archive-dir "$dist" --version "$version"
}

step_publish() {
  local now
  if [[ "$dry_run" == false ]]; then
    check_release_runs
    now="$("${DIST_ROOT}/scripts/next-version.sh" "$tag" "$repo")"
    [[ "$now" == "$version" ]] || die "the next version is now ${now}, not ${version}: published meanwhile; nothing published"
    "${DIST_ROOT}/scripts/publish.sh" --built-on "$built_on" "$repo" "$version" "$tag" "$dist" "$commit"
  else
    "${DIST_ROOT}/scripts/publish.sh" --dry-run --built-on "$built_on" "$repo" "$version" "$tag" "$dist" "$commit"
  fi
}

[[ "$dry_run" == false ]] || log "Dry run: every step except the publication"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"
commit="$(git -C "$DIST_ROOT" rev-parse HEAD)"
check_checkout
check_release_runs
version=""
run_step plan step_plan
run_step prepare step_prepare
run_step test step_test
run_step build step_build
run_step package step_package
run_step smoke step_smoke
run_step publish step_publish
