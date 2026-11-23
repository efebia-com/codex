#!/usr/bin/env bash
# Tests for install.sh against fake releases served on 127.0.0.1.
#
# Usage: tests/install/run.sh
#
# Needs python3, curl and tar; no network. HOME points to a temporary
# directory, so nothing outside it is touched. A fake uname makes the host look
# like Linux x86_64, or like the platform a test chooses.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="${root}/install.sh"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'; else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}

# Releases are published for Linux x86_64 only.
targets=(x86_64-unknown-linux-musl)
latest=1.1.0-efebia
versions=(1.0.0-ext.1 1.0.0-ext.2 "$latest")
for version in "${versions[@]}"; do
  out="${work}/site/releases/download/v${version}"
  mkdir -p "$out"
  for target in "${targets[@]}"; do
    pkg="${work}/build/codex-${version}-${target}"
    mkdir -p "${pkg}/bin"
    # Like the real one, it writes under CODEX_HOME whenever it runs.
    # shellcheck disable=SC2016 # expanded by the fake binary
    printf '#!/bin/sh\nmkdir -p "${CODEX_HOME:-$HOME/.codex}/tmp"\necho "codex-cli fake %s"\n' "$version" >"${pkg}/bin/codex"
    chmod 0755 "${pkg}/bin/codex"
    printf 'version=%s\ntarget=%s\n' "$version" "$target" >"${pkg}/DISTRIBUTION"
    cp "$installer" "${pkg}/install.sh"
    tar -C "${work}/build" -czf "${out}/codex-${target}.tar.gz" "codex-${version}-${target}"
    printf '%s  %s\n' "$(sha256 "${out}/codex-${target}.tar.gz")" "codex-${target}.tar.gz" >>"${out}/SHA256SUMS"
  done
done

python3 -I "${root}/tests/install/server.py" "${work}/site" "${work}/port" "$latest" &
server_pid=$!
for _ in $(seq 50); do
  [[ -s "${work}/port" ]] && break
  sleep 0.1
done
[[ -s "${work}/port" ]] || { echo "server did not start"; exit 1; }

real_uname="$(command -v uname)"
mkdir -p "${work}/fakebin"
cat >"${work}/fakebin/uname" <<FAKE
#!/bin/sh
case "\${1:-}" in
  -s) echo "\${FAKE_UNAME_S:-Linux}" ;;
  -m) echo "\${FAKE_UNAME_M:-x86_64}" ;;
  *) exec "${real_uname}" "\$@" ;;
esac
FAKE
chmod 0755 "${work}/fakebin/uname"
export PATH="${work}/fakebin:${PATH}"

export HOME="${work}/home"
# The installer and the fake codex default CODEX_HOME to $HOME/.codex: one inherited
# from the calling shell (a Codex session sets it) would point them outside the test.
unset CODEX_HOME
mkdir -p "$HOME"
E_CODEX_DOWNLOAD_BASE="http://127.0.0.1:$(cat "${work}/port")/releases"
export E_CODEX_DOWNLOAD_BASE
prefix="${HOME}/e-codex"
run_install() { sh "$installer" --prefix "$prefix" "$@" >"${work}/out" 2>&1; }
output_has() { grep -q -- "$1" "${work}/out"; }
fails() { ! "$@"; }
run_update() { "${prefix}/bin/codex-update" "$@" >"${work}/out" 2>&1; }
release_count() { find "${prefix}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }
installed() { CODEX_HOME="${work}/codex-home" "${prefix}/bin/codex" | grep -q "fake $1"; }

check "installs a given version" run_install --version 1.0.0-ext.1
check "installed binary runs from <prefix>/bin" installed 1.0.0-ext.1
check "creates the update command" test -x "${prefix}/bin/codex-update"
check "marks the prefix as its own" test -f "${prefix}/.e-codex"

check "--check reports the update" run_install --check
check "--check names both versions" output_has "1.0.0-ext.1 -> ${latest}"

sleep 1
check "codex-update installs the latest release" run_update
check "the latest release is active" installed "$latest"
check "the previous release is kept" test "$(release_count)" = 2

sleep 1
check "codex-update accepts a version" run_update --version 1.0.0-ext.2
check "only the active and the previous release remain" test "$(release_count)" = 2
check "the oldest release was removed" test -z "$(find "${prefix}/releases" -name '1.0.0-ext.1-*')"

check "reinstalling the active version is a no-op" run_install --version 1.0.0-ext.2
check "and says so" output_has "already installed"

sed -i.bak 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
  "${work}/site/releases/download/v1.0.0-ext.1/SHA256SUMS"
check "a checksum mismatch fails" fails run_install --version 1.0.0-ext.1
check "and reports it" output_has "checksum mismatch"
check "and leaves the active release alone" installed 1.0.0-ext.2

check "a missing release fails" fails run_install --version 9.9.9-ext.1

run_install_on() {
  FAKE_UNAME_S="$1" FAKE_UNAME_M="$2" sh "$installer" --prefix "$prefix" --version "$latest" >"${work}/out" 2>&1
}
prefix="${HOME}/unsupported"
for platform in "Linux aarch64" "Linux arm64" "Darwin arm64" "Darwin x86_64" "FreeBSD amd64"; do
  read -r os arch <<<"$platform"
  check "${os} ${arch} is refused" fails run_install_on "$os" "$arch"
  check "with a clear message" output_has "unsupported platform: ${os} ${arch}. e-codex is published for Linux x86_64 only"
  check "before anything is written" test ! -e "$prefix"
done

prefix="${HOME}/.codex/packages/standalone/releases/x"
check "a prefix inside CODEX_HOME is refused" fails run_install --version "$latest"
check "and nothing is created there" test ! -e "${HOME}/.codex"

prefix="${HOME}/other"
mkdir -p "$prefix"
echo data >"${prefix}/file"
check "a non-empty foreign directory is refused" fails run_install --version "$latest"

# What older installers left: their marker and their variables still work.
prefix="${HOME}/older"
mkdir -p "${prefix}/releases"
: >"${prefix}/.codex-ext"
check "a prefix of an older installer is accepted" run_install --version "$latest"
check "and keeps its older marker" test -f "${prefix}/.codex-ext"

run_install_older_variables() {
  env -u E_CODEX_DOWNLOAD_BASE CODEX_EXT_DOWNLOAD_BASE="$E_CODEX_DOWNLOAD_BASE" CODEX_EXT_PREFIX="$prefix" \
    sh "$installer" --version "$latest" >"${work}/out" 2>&1
}
prefix="${HOME}/variables/older"
check "the CODEX_EXT_ variables apply without the E_CODEX_ ones" run_install_older_variables
check "in the prefix they name" installed "$latest"

run_install_new_prefix() {
  E_CODEX_PREFIX="$prefix" CODEX_EXT_PREFIX="${HOME}/variables/ignored" sh "$installer" --version "$latest" >"${work}/out" 2>&1
}
prefix="${HOME}/variables/new"
check "E_CODEX_PREFIX wins over CODEX_EXT_PREFIX" run_install_new_prefix
check "in the prefix it names" installed "$latest"
check "and nothing goes to the other" test ! -e "${HOME}/variables/ignored"

old_default="${HOME}/.local/share/codex-ext"
mkdir -p "$old_default"
: >"${old_default}/.codex-ext"
run_install_default() { sh "$installer" --version "$latest" >"${work}/out" 2>&1; }
prefix="${HOME}/.local/share/e-codex"
check "installs into ~/.local/share/e-codex by default" run_install_default
check "and runs from there" installed "$latest"
check "names the older installation in ~/.local/share/codex-ext" output_has "An older installation is still in ${old_default}"
check "and leaves it alone" test "$(ls -A "$old_default")" = .codex-ext

check "nothing was written outside the prefixes" test "$(cd "$HOME" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')" = "./.local ./e-codex ./older ./other ./variables "

echo
if ((failures > 0)); then
  echo "${failures} installer test(s) failed"
  exit 1
fi
echo "All installer tests passed"
