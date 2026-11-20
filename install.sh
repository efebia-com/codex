#!/bin/sh
# Install or update Codex with extensions in a directory of your choice.
#
#   curl -fsSL https://github.com/efebia-com/codex/releases/latest/download/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --prefix "$HOME/opt/codex-ext"
#
# Layout of the prefix (default: ~/.local/share/codex-ext):
#   releases/<version>-<target>/   unpacked release packages
#   current -> releases/...        the active release
#   bin/codex                      the Codex entrypoint (symlink into current)
#   bin/codex-update               runs this installer again for this prefix
#
# Nothing outside the prefix is touched: not other Codex installations, not
# ~/.codex, not shell profiles. Add <prefix>/bin to PATH yourself.
#
# Releases are published for Linux x86_64 only; on any other platform the
# installer stops before it writes anything.

set -eu

REPO="${CODEX_EXT_REPO:-efebia-com/codex}"
PREFIX="${CODEX_EXT_PREFIX:-${HOME}/.local/share/codex-ext}"
VERSION="latest"
CHECK_ONLY=false
KEEP=2
# Base URL of the release downloads; overridable to test against a local mirror.
DOWNLOAD_BASE="${CODEX_EXT_DOWNLOAD_BASE:-https://github.com/${REPO}/releases}"

usage() {
  cat <<EOF
Usage: install.sh [--prefix DIR] [--version VERSION] [--check]

  --prefix DIR       install directory (default: ${PREFIX})
  --version VERSION  release to install, e.g. 0.171.0-efebia (default: latest)
  --check            only report whether an update is available
  -h, --help         show this help

Environment: CODEX_EXT_PREFIX, CODEX_EXT_REPO (default efebia-com/codex).
EOF
}

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || die "--version needs a value"; VERSION="${2#v}"; shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}/${arch}" in
    Linux/x86_64|Linux/amd64) echo x86_64-unknown-linux-musl ;;
    *) die "unsupported platform: ${os} ${arch}. Codex with extensions is published for Linux x86_64 only" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    die "sha256sum or shasum is required"
  fi
}

# Absolute path of a directory that may not exist yet.
absolute_dir() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd)" "$1" ;;
  esac
}

# Refuse prefixes where Codex would believe it was installed by another
# installer and offer that installer's update command (which installs upstream).
check_prefix() {
  codex_home="${CODEX_HOME:-${HOME}/.codex}"
  case "$PREFIX/" in
    "$codex_home"/*)
      die "the prefix must not be inside ${codex_home}: Codex would treat it as its own standalone install" ;;
  esac
  if [ -d "$PREFIX" ] && [ ! -f "$PREFIX/.codex-ext" ] && [ -n "$(ls -A "$PREFIX" 2>/dev/null)" ]; then
    die "$PREFIX exists, is not empty and was not created by this installer"
  fi
}

installed_version() {
  dist="$PREFIX/current/DISTRIBUTION"
  [ -f "$dist" ] && sed -n 's/^version=//p' "$dist"
}

# Tag of the latest release, from the redirect of /releases/latest.
latest_version() {
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${DOWNLOAD_BASE}/latest")" ||
    die "cannot reach ${DOWNLOAD_BASE}/latest"
  tag="${url##*/}"
  case "$tag" in
    v[0-9]*) printf '%s\n' "${tag#v}" ;;
    *) die "no release found at ${DOWNLOAD_BASE}" ;;
  esac
}

download() {
  curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"
}

# First: an unsupported platform stops here, before anything is checked or written.
target="$(detect_target)"
PREFIX="$(absolute_dir "$PREFIX")"
check_prefix
current="$(installed_version || true)"

if [ "$VERSION" = latest ]; then
  VERSION="$(latest_version)"
fi

if [ "$CHECK_ONLY" = true ]; then
  if [ -z "$current" ]; then
    say "Not installed in ${PREFIX}; available: ${VERSION}"
  elif [ "$current" = "$VERSION" ]; then
    say "Up to date: ${current}"
  else
    say "Update available: ${current} -> ${VERSION} (run ${PREFIX}/bin/codex-update)"
  fi
  exit 0
fi

release_name="${VERSION}-${target}"
release_dir="$PREFIX/releases/${release_name}"
if [ "$current" = "$VERSION" ] && [ -d "$release_dir" ]; then
  say "Codex ${VERSION} is already installed in ${PREFIX}"
  exit 0
fi

mkdir -p "$PREFIX/releases" "$PREFIX/bin"
: >"$PREFIX/.codex-ext"
tmp="$(mktemp -d "$PREFIX/.install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

asset="codex-${target}.tar.gz"
say "Downloading Codex ${VERSION} for ${target}"
download "${DOWNLOAD_BASE}/download/v${VERSION}/${asset}" "$tmp/$asset"
download "${DOWNLOAD_BASE}/download/v${VERSION}/SHA256SUMS" "$tmp/SHA256SUMS"

expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")"
[ -n "$expected" ] || die "${asset} is not listed in SHA256SUMS"
actual="$(sha256_of "$tmp/$asset")"
[ "$expected" = "$actual" ] || die "checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
say "Checksum verified"

mkdir "$tmp/unpack"
tar -xzf "$tmp/$asset" -C "$tmp/unpack"
unpacked="$tmp/unpack/codex-${VERSION}-${target}"
[ -x "$unpacked/bin/codex" ] && [ -f "$unpacked/DISTRIBUTION" ] ||
  die "unexpected archive layout in ${asset}"

rm -rf "$release_dir"
mv "$unpacked" "$release_dir"
touch "$release_dir" # install time, used below to keep the newest releases
ln -sfn "releases/${release_name}" "$PREFIX/current"
ln -sfn "../current/bin/codex" "$PREFIX/bin/codex"
cat >"$PREFIX/bin/codex-update" <<EOF
#!/bin/sh
# Update the Codex installation in this prefix to the latest release.
exec sh "${PREFIX}/current/install.sh" --prefix "${PREFIX}" "\$@"
EOF
chmod 0755 "$PREFIX/bin/codex-update"

# Keep the active release and the newest previous ones, for rollback.
# shellcheck disable=SC2012 # names are <version>-<target>; ls sorts by mtime
ls -1t "$PREFIX/releases" | awk -v keep="$KEEP" -v cur="$release_name" '$0 != cur { n++; if (n >= keep) print }' |
  while IFS= read -r old; do
    rm -rf "${PREFIX:?}/releases/${old}"
  done

say "Installed Codex ${VERSION} in ${PREFIX}"
# A scratch CODEX_HOME: even --version sets up helper links under CODEX_HOME, and
# the installer writes nothing outside the prefix.
mkdir "$tmp/codex-home"
CODEX_HOME="$tmp/codex-home" "$PREFIX/bin/codex" --version || die "the installed binary does not run"
case ":${PATH}:" in
  *":${PREFIX}/bin:"*) ;;
  *) say "Add it to your PATH, for example: export PATH=\"${PREFIX}/bin:\$PATH\"" ;;
esac
say "If you use the TUI's background server, pin it to this release (it restarts it):"
say "  ${PREFIX}/bin/codex app-server daemon start"
say "  ${PREFIX}/bin/codex app-server daemon update --from-cli --yes"
