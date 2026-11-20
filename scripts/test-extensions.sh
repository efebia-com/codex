#!/usr/bin/env bash
# Run the extension tests listed in patches/tests on a prepared source tree.
#
# Usage: scripts/test-extensions.sh --source <dir>
#
# Each line of patches/tests is `<extension>: <cargo test arguments>` and runs
# as one `cargo test --no-fail-fast` from codex-rs/. Lines of extensions that are not in
# patches/series are skipped, and a command listed twice runs once. Every
# command runs even after a failure; the summary lists the failures. A command
# that runs no test at all (a filter matching nothing) counts as a failure.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require cargo

[[ "${1:-}" == "--source" && -n "${2:-}" ]] || die "usage: $0 --source <dir>"
source_dir="$(cd "$2" && pwd)"
codex_rs="${source_dir}/codex-rs"
[[ -f "${codex_rs}/Cargo.toml" ]] || die "not a Codex source tree: $2"
ensure_v8 "$source_dir" "$(cd "$codex_rs" && host_target)"

# Use the upstream Rust CI stack size for debug test threads.
export RUST_MIN_STACK="${RUST_MIN_STACK:-8388608}"

mapfile -t extensions < <(series_extensions)
in_series() {
  local extension
  for extension in "${extensions[@]}"; do
    [[ "$extension" == "$1" ]] && return 0
  done
  return 1
}

passed=()
failed=()
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
declare -A seen=()
# fd 3: cargo test must not consume the list from stdin.
while IFS= read -r line <&3; do
  extension="${line%%:*}"
  read -r -a args <<<"${line#*:}"
  [[ "$line" == *:* && ${#args[@]} -gt 0 ]] || die "patches/tests: expected '<extension>: <cargo test args>', got: $line"
  if ! in_series "$extension"; then
    log "Skipping ${extension}: not in patches/series"
    continue
  fi
  command="cargo test --no-fail-fast ${args[*]}"
  if [[ -n "${seen["$command"]:-}" ]]; then
    log "${extension}: ${command} (already run)"
    continue
  fi
  seen["$command"]=1
  log "${extension}: ${command}"
  if (cd "$codex_rs" && cargo test --no-fail-fast "${args[@]}") 2>&1 | tee "$output"; then
    # A filter that matches nothing passes silently: count what ran.
    ran="$(awk '/^test result:/ { n += $4 + $6 } END { print n + 0 }' "$output")"
    if ((ran > 0)); then
      passed+=("${extension}: ${command}")
    else
      failed+=("${extension}: ${command} (no test matched)")
    fi
  else
    failed+=("${extension}: ${command}")
  fi
done 3< <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${PATCHES_DIR}/tests" | awk 'NF')

echo
echo "Extension tests: ${#passed[@]} passed, ${#failed[@]} failed"
for entry in "${passed[@]}"; do echo "  PASS  $entry"; done
for entry in "${failed[@]}"; do echo "  FAIL  $entry"; done
((${#failed[@]} == 0)) || die "extension tests failed: ${failed[*]}"
