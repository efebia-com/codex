#!/usr/bin/env bash
# Run the extension tests listed in patches/tests on a prepared source tree.
#
# Usage: scripts/test-extensions.sh --source <dir>
#
# Each line of patches/tests is `<extension>: <cargo test arguments>`, run from
# codex-rs/. Lines of extensions that are not in patches/series are skipped, and a
# command listed twice runs once. The arguments are one package (-p), optional
# target selectors (--lib, --bin <name>, --test <name>; none means every test
# target of the package, as cargo test) and an optional test name filter.
#
# Every test binary is built by a single `cargo test --no-run` over all the
# listed packages, so the dependency graph is compiled once, with the features
# of all those packages unified (as `cargo test --workspace` does). Cargo then
# runs once more with a runner that only records the environment and directory
# it gives each binary. Each line then runs its binaries in that environment,
# with its filter. Every line runs even after a failure; the summary lists the
# failures. A line that runs no test at all (a filter matching nothing) counts
# as a failure.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require cargo jq

[[ "${1:-}" == "--source" && -n "${2:-}" ]] || die "usage: $0 --source <dir>"
source_dir="$(cd "$2" && pwd)"
codex_rs="${source_dir}/codex-rs"
[[ -f "${codex_rs}/Cargo.toml" ]] || die "not a Codex source tree: $2"
host="$(cd "$codex_rs" && host_target)"
ensure_v8 "$source_dir" "$host"

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Read patches/tests into one entry per distinct command. ---
# Selectors are space-separated: lib, bin:<name>, test:<name>; empty means all.
line_extension=()
line_command=()
line_package=()
line_selectors=()
line_filter=()
declare -A seen=()
while IFS= read -r line; do
  extension="${line%%:*}"
  read -r -a args <<<"${line#*:}"
  [[ "$line" == *:* && ${#args[@]} -gt 0 ]] || die "patches/tests: expected '<extension>: <cargo test args>', got: $line"
  if ! in_series "$extension"; then
    log "Skipping ${extension}: not in patches/series"
    continue
  fi
  command="cargo test --no-fail-fast ${args[*]}"
  if [[ -n "${seen["$command"]:-}" ]]; then
    log "${extension}: ${command} (already listed)"
    continue
  fi
  seen["$command"]=1
  package="" selectors="" filter=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      -p | --package) package="${args[++i]:-}" ;;
      --lib) selectors+=" lib" ;;
      --bin | --test) selectors+=" ${args[i]#--}:${args[++i]:-}" ;;
      -*) die "patches/tests: unsupported option ${args[i]} in: $line" ;;
      *)
        [[ -z "$filter" ]] || die "patches/tests: more than one test name filter in: $line"
        filter="${args[i]}"
        ;;
    esac
  done
  [[ -n "$package" && "$selectors" != *": "* && "$selectors" != *":" ]] ||
    die "patches/tests: expected one -p <package> and named --bin/--test targets in: $line"
  line_extension+=("$extension")
  line_command+=("$command")
  line_package+=("$package")
  line_selectors+=("${selectors# }")
  line_filter+=("$filter")
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${PATCHES_DIR}/tests" | awk 'NF')
((${#line_command[@]} > 0)) || die "patches/tests: no test to run"

# --- Cargo arguments that build every listed test target. ---
(cd "$codex_rs" && cargo metadata --format-version 1 --no-deps) >"${tmp}/metadata.json"
declare -A selected=()
build_args=()
add_selector() {
  [[ -n "${selected["$1"]:-}" ]] && return 0
  selected["$1"]=1
  case "$1" in
    lib) build_args+=(--lib) ;;
    *) build_args+=("--${1%%:*}" "${1#*:}") ;;
  esac
}
doc_packages=()
for ((n = 0; n < ${#line_command[@]}; n++)); do
  package="${line_package[n]}"
  if [[ -z "${selected["package:${package}"]:-}" ]]; then
    selected["package:${package}"]=1
    jq -e --arg p "$package" '.packages | any(.name == $p)' "${tmp}/metadata.json" >/dev/null ||
      die "patches/tests: no package ${package} in the workspace"
    build_args+=(-p "$package")
  fi
  if [[ -n "${line_selectors[n]}" ]]; then
    for selector in ${line_selectors[n]}; do add_selector "$selector"; done
    continue
  fi
  # No selector: every target that cargo test runs for the package.
  while IFS= read -r selector; do
    add_selector "$selector"
  done < <(jq -r --arg p "$package" '
    .packages[] | select(.name == $p) | .targets[] | select(.test) |
    if (.kind | index("bin")) then "bin:\(.name)"
    elif (.kind | index("test")) then "test:\(.name)"
    elif (.kind | index("example")) then "example:\(.name)"
    elif (.kind | index("bench")) then empty
    else "lib" end' "${tmp}/metadata.json")
  # Doctests are not built by --no-run: such lines also run `cargo test --doc`.
  if jq -e --arg p "$package" '.packages[] | select(.name == $p) | any(.targets[]; .doctest)' \
    "${tmp}/metadata.json" >/dev/null; then
    doc_packages[n]=1
  fi
done

# --- Build every test binary once. ---
log "Building the tests: cargo test --no-run ${build_args[*]}"
start=$SECONDS
(cd "$codex_rs" && cargo test --no-run --message-format=json-render-diagnostics "${build_args[@]}") \
  >"${tmp}/artifacts.json" || die "extension tests failed to build"
log "Tests built in $((SECONDS - start)) s"

# --- Record the environment and directory cargo gives each test binary. ---
records="${tmp}/records"
mkdir -p "$records"
cat >"${tmp}/record-runner" <<EOF
#!/usr/bin/env bash
set -euo pipefail
name="\$(basename "\$1")"
pwd >"${records}/\${name}.cwd"
env -0 >"${records}/\${name}.env"
EOF
chmod +x "${tmp}/record-runner"
runner_var="CARGO_TARGET_$(tr 'a-z-' 'A-Z_' <<<"$host")_RUNNER"
(cd "$codex_rs" && env "${runner_var}=${tmp}/record-runner" cargo test --quiet --no-fail-fast "${build_args[@]}" >/dev/null) ||
  die "could not record the test environments"

# Test executables of one line, from the build's artifact messages.
line_executables() {
  local package="$1" selectors="$2" id
  id="$(jq -r --arg p "$package" '.packages[] | select(.name == $p) | .id' "${tmp}/metadata.json")"
  jq -r --arg id "$id" --arg selectors "$selectors" '
    select(.reason == "compiler-artifact" and .profile.test and .executable != null
      and .package_id == $id) |
    (if (.target.kind | index("bin")) then "bin:\(.target.name)"
     elif (.target.kind | index("test")) then "test:\(.target.name)"
     elif (.target.kind | index("example")) then "example:\(.target.name)"
     else "lib" end) as $selector |
    select($selectors == "" or (($selectors | split(" ")) | index($selector))) |
    .executable' "${tmp}/artifacts.json"
}

# Run one test binary as cargo test would, with an optional filter.
run_executable() {
  local executable="$1" filter="$2" name environment
  name="$(basename "$executable")"
  [[ -f "${records}/${name}.env" ]] || {
    echo "error: no recorded environment for ${executable}" >&2
    return 1
  }
  mapfile -d '' environment <"${records}/${name}.env"
  echo "     Running ${executable#"${codex_rs}/"}"
  (cd "$(cat "${records}/${name}.cwd")" && env -i "${environment[@]}" "$executable" ${filter:+"$filter"})
}

passed=()
failed=()
output="${tmp}/output"
for ((n = 0; n < ${#line_command[@]}; n++)); do
  extension="${line_extension[n]}"
  command="${line_command[n]}"
  filter="${line_filter[n]}"
  log "${extension}: ${command}"
  mapfile -t executables < <(line_executables "${line_package[n]}" "${line_selectors[n]}")
  status=0
  : >"$output"
  if ((${#executables[@]} == 0)); then
    echo "error: no test binary built for: ${command}" >&2
    status=1
  fi
  for executable in "${executables[@]}"; do
    run_executable "$executable" "$filter" 2>&1 | tee -a "$output" || status=1
  done
  if [[ -n "${doc_packages[n]:-}" ]]; then
    (cd "$codex_rs" && cargo test --no-fail-fast --doc -p "${line_package[n]}" ${filter:+"$filter"}) 2>&1 |
      tee -a "$output" || status=1
  fi
  if ((status == 0)); then
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
done

echo
echo "Extension tests: ${#passed[@]} passed, ${#failed[@]} failed"
for entry in "${passed[@]}"; do echo "  PASS  $entry"; done
for entry in "${failed[@]}"; do echo "  FAIL  $entry"; done
((${#failed[@]} == 0)) || die "extension tests failed: ${failed[*]}"
