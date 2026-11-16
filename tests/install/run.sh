#!/usr/bin/env bash
# Tests for install.sh against fake releases served on 127.0.0.1.
#
# Usage: tests/install/run.sh
#
# Needs python3, curl and tar; no network. HOME points to a temporary
# directory, so nothing outside it is touched.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="${root}/install.sh"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
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

# Fake releases for every target, so the test does not depend on the host.
targets=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin)
versions=(1.0.0-ext.1 1.0.0-ext.2 1.1.0-ext.1)
latest=1.1.0-ext.1
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

export HOME="${work}/home"
mkdir -p "$HOME"
CODEX_EXT_DOWNLOAD_BASE="http://127.0.0.1:$(cat "${work}/port")/releases"
export CODEX_EXT_DOWNLOAD_BASE
prefix="${HOME}/codex-ext"
run_install() { sh "$installer" --prefix "$prefix" "$@" >"${work}/out" 2>&1; }
output_has() { grep -q -- "$1" "${work}/out"; }
fails() { ! "$@"; }
run_update() { "${prefix}/bin/codex-update" "$@" >"${work}/out" 2>&1; }
release_count() { find "${prefix}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }
installed() { CODEX_HOME="${work}/codex-home" "${prefix}/bin/codex" | grep -q "fake $1"; }

check "installs a given version" run_install --version 1.0.0-ext.1
check "installed binary runs from <prefix>/bin" installed 1.0.0-ext.1
check "creates the update command" test -x "${prefix}/bin/codex-update"

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

prefix="${HOME}/.codex/packages/standalone/releases/x"
check "a prefix inside CODEX_HOME is refused" fails run_install --version "$latest"
check "and nothing is created there" test ! -e "${HOME}/.codex"

prefix="${HOME}/other"
mkdir -p "$prefix"
echo data >"${prefix}/file"
check "a non-empty foreign directory is refused" fails run_install --version "$latest"

check "nothing was written outside the prefixes" test "$(cd "$HOME" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')" = "./codex-ext ./other "

echo
if ((failures > 0)); then
  echo "${failures} installer test(s) failed"
  exit 1
fi
echo "All installer tests passed"
