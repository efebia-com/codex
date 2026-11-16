# Codex with extensions

Builds of [OpenAI Codex](https://github.com/openai/codex) with optional
extensions, kept as small patch series on top of the stable upstream releases.

Every extension is opt-in: without the configuration that enables it, Codex
behaves exactly like the upstream release it is built from. The `codex --version`
output is the upstream version.

## Extensions

The extensions are the series listed in [`patches/series`](patches/series).
Each release lists the patches it contains and the files they change, in its
notes and in `MODIFICATIONS.md` inside the archive.

## Install

Linux (x86_64, aarch64) and macOS (Apple silicon, Intel):

```sh
curl -fsSL https://github.com/efebia-com/codex/releases/latest/download/install.sh | sh
```

To choose the directory (default `~/.local/share/codex-ext`):

```sh
curl -fsSL https://github.com/efebia-com/codex/releases/latest/download/install.sh | sh -s -- --prefix "$HOME/opt/codex-ext"
```

The installer downloads the archive for your platform, checks its SHA-256
against the release's `SHA256SUMS`, and unpacks it into the prefix:

```text
<prefix>/
├── releases/<version>-<target>/   unpacked releases (the active one and the previous one)
├── current -> releases/...
└── bin/
    ├── codex                      the Codex entrypoint
    └── codex-update               updates this prefix
```

It changes nothing outside the prefix: other Codex installations, `~/.codex`
and shell profiles stay as they are. Add `<prefix>/bin` to your `PATH` (it prints
the line to use); whichever `codex` comes first in `PATH` is the one that runs.
It refuses prefixes inside `$CODEX_HOME` and, on macOS, under `/opt/homebrew`
or `/usr/local`, where Codex would think it had been installed by its own
installer or by Homebrew and would offer their update commands.

Options: `--version <version>` installs a given release, `--check` only reports
whether an update is available. To uninstall, delete the prefix.

### Update

```sh
<prefix>/bin/codex-update            # latest release
<prefix>/bin/codex-update --check    # only check
<prefix>/bin/codex-update --version 0.169.0-ext.1
```

The previous release stays in `<prefix>/releases/`; to roll back, run
`codex-update --version <previous version>`.

Codex itself checks for new upstream releases and may show "Update available!"
with a link to the upstream repository. That notice is about upstream Codex: a
release of this distribution follows each stable upstream release once the
patches apply and the build and tests pass. Use `codex-update` to update. To
hide the notice, set `check_for_update_on_startup = false` in
`~/.codex/config.toml`; note that this file is shared with any other Codex
installation.

### Background server (daemon)

The TUI normally runs on a shared background server, the daemon
(`codex app-server daemon`). The daemon keeps its own copy of a Codex release in
`$CODEX_HOME/packages/app-server-daemon/`. When this distribution's `codex`
starts it for the first time, it copies the installed release but marks the
copy to follow upstream updates: at the next upstream release the daemon would
replace it with upstream Codex, which has none of the extensions.

Pin the daemon to the installed release once after installing, and again after
every `codex-update`:

```sh
<prefix>/bin/codex app-server daemon start                # sets the daemon up; no-op if it runs
<prefix>/bin/codex app-server daemon update --from-cli --yes
<prefix>/bin/codex app-server daemon version              # what the daemon runs now
```

`update --from-cli` needs a daemon that has been set up, hence the `start`
first. It copies the release of the `codex` you run it with and turns the
upstream updates off; it restarts the daemon, so it may interrupt running work.
The pin holds when the daemon stops and starts again. Until the daemon is
pinned, its updater (`codex app-server daemon pid-update-loop`) keeps running
even after `codex app-server daemon stop`; pinning stops it.
`codex app-server daemon update`, without `--from-cli`, goes back to upstream
updates. The daemon belongs to `$CODEX_HOME`, so every Codex installation that
uses the same `$CODEX_HOME` shares it.

To avoid the daemon altogether, start the TUI with `codex --no-daemon`.

### macOS

The binaries are not signed with a Developer ID nor notarized. Files downloaded
with `curl`, as the installer does, do not get the quarantine attribute, so
Gatekeeper does not block them. If you download an archive with a browser,
remove the attribute before running it:

```sh
xattr -dr com.apple.quarantine codex-<version>-<target>
```

## Versions

Releases are tagged `v<upstream version>-ext.<revision>`, for example
`v0.169.0-ext.1`:

- `<upstream version>` is the upstream release the build comes from
  (`rust-v0.169.0`);
- `<revision>` starts at 1 for each upstream version and grows when the same
  upstream version is published again with changed patches.

The version is recorded in `DISTRIBUTION` inside each package.

## How releases are made

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs every 30
minutes. When upstream has a stable release (`rust-vX.Y.Z`, not a prerelease)
that is not published here yet, it:

1. applies the patch series to the upstream tag; a conflict stops the run
   before anything is built;
2. runs the extension tests (Linux);
3. builds `codex` for `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`,
   `aarch64-apple-darwin` and `x86_64-apple-darwin`, with the build settings of
   the upstream release workflow;
4. installs each package with `install.sh` on its own platform and runs the
   smoke tests in [`tests/e2e/`](tests/e2e);
5. publishes the release only if every step passed.

If any step fails, nothing is published, the previous release stays current,
and an issue labelled `release-failure` names the failed step with the end of
its log. While that issue is open the scheduled check does not retry the same
upstream version; close it after fixing the cause, or run the workflow by hand.
Running it by hand with `force` publishes a new revision of an upstream version
that is already published.

## Build locally

```sh
scripts/upstream-latest.sh                          # newest stable upstream tag
scripts/prepare-source.sh rust-v0.169.0 .work/src   # fetch the tag, apply patches/series
scripts/test-extensions.sh --source .work/src       # tests listed in patches/tests
scripts/build.sh --source .work/src --out .work/pkg # debug build for this machine
```

`build.sh --release --target <triple>` is the release build used by CI; the
Linux musl targets need the toolchain that the workflow installs. The scripts
need bash 4 or newer, git, curl, jq, python3 and the Rust toolchain pinned by
the upstream source.

## Patch series

- `patches/<extension>/` holds one series, generated with `git format-patch`.
  Its patches are applied in name order with `git am --3way`.
- `patches/series` lists the series in the order they are applied; each series
  applies on top of the previous ones.
- `patches/base` is the upstream tag the series were generated against. It is
  fetched next to the release tag so that `git am --3way` can merge patches
  whose context moved upstream.
- `patches/tests` lists the `cargo test` commands of each extension.

Patches do not include `Cargo.lock`. After applying them, `prepare-source.sh`
runs `cargo update --workspace` to record new workspace crates and fails if any
other locked dependency would change, so patches can only use dependencies that
upstream already locks.

## License

Codex is licensed under the Apache License 2.0 by OpenAI; see [LICENSE](LICENSE).
The patches in this repository are modifications of Codex under the same
license. Each release archive contains the upstream `LICENSE` and `NOTICE`, the
patches, and `MODIFICATIONS.md`, which lists the changed files.
