# Codex with extensions

Builds of [OpenAI Codex](https://github.com/openai/codex) with optional
extensions, kept as small patch series on top of the stable upstream releases.

Every extension is opt-in: without the configuration that enables it, Codex
behaves exactly like the upstream release it is built from. The only addition
that is on by default is the [process status file](#process-status-file), which
does not change what Codex does. The `codex --version` output is the upstream
version.

## Extensions

The extensions are the series listed in [`patches/series`](patches/series).
Each release lists the patches it contains and the files they change, in its
notes and in `MODIFICATIONS.md` inside the archive.

## Process status file

While the interactive Codex (the TUI) runs, it keeps a small JSON file that says
which conversation it shows, so other programs can find it without reading the
screen: `$CODEX_HOME/processes/<pid>.json` (`~/.codex/processes/` by default).
It has the same fields as the file Claude Code writes in `~/.claude/sessions/`:
`pid`, `procStart`, `sessionId` (the conversation, `null` before the first one),
`cwd`, `tmux` (`session:@window.%pane` inside tmux), `status` (`busy` or
`idle`), `kind`, `version`, `startedAt`, `updatedAt` and `statusUpdatedAt`.

The file is written atomically when the TUI starts (with `sessionId` `null` on
the startup screens and pickers), when the conversation on screen changes (`/new`, `/clear`, `/resume`, fork), when the working directory
changes, and when a turn starts or ends. It is removed when Codex exits. A file
left by a killed process is removed by the next Codex that starts; readers
should still check that `pid` and `procStart` match a running process.

To turn it off, set `CODEX_PROCESS_STATUS_FILE=0` (`false`, `off` and `no` also
work) in the environment Codex starts with. Details:
[`patches/process-status-file/README.md`](patches/process-status-file/README.md).

## Install

Linux x86_64 (releases are published for this platform only; on any other the
installer stops with an error):

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
It refuses prefixes inside `$CODEX_HOME`, where Codex would think it had been
installed by its own installer and would offer that installer's update command.

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

## Versions

The first release for a stable upstream tag uses the upstream version with an
`-efebia` suffix. For example, `rust-v0.171.0` is published as
`v0.171.0-efebia`. Forced releases with updated patches append `.2`, `.3` and
so on. The installer also accepts older `-ext.N` releases.

New releases report the distribution version in `codex --version` and in the
package's `DISTRIBUTION` file.

## How releases are made

Every 30 minutes a build machine runs
[`scripts/release-scheduled.sh`](scripts/release-scheduled.sh) (see below).
When upstream has a stable release (`rust-vX.Y.Z`, not a prerelease) that is
not published here yet, it:

1. applies the patch series to the upstream tag; a conflict stops the run
   before anything is built;
2. runs the extension tests (Linux);
3. builds `codex` for `x86_64-unknown-linux-musl`, the only published
   platform, with the build settings of the upstream release workflow;
4. installs each package with `install.sh` on its own platform and runs the
   smoke tests in [`tests/e2e/`](tests/e2e);
5. publishes the release only if every step passed.

If any step fails, nothing is published, the previous release stays current,
and an issue labelled `release-failure` names the failed step with the end of
its log. While that issue is open the scheduled check does not retry the same
upstream version; close it after fixing the cause, or start the release by hand.

[`.github/workflows/release.yml`](.github/workflows/release.yml) makes the same
release on GitHub Actions when run by hand. With `force` it publishes a new
revision of an upstream version that is already published; `targets` (e.g.
`x86_64-unknown-linux-musl`) limits it to some packages, and a later forced run
adds the others.

## Releases built on a build machine

[`scripts/release-local.sh`](scripts/release-local.sh) makes the same release
as the workflow, for `x86_64-unknown-linux-musl` only, on a Linux x86_64
machine: version check, patches, extension tests, release build with the
upstream build settings, packaging, `install.sh` smoke tests, and publication
with `gh`. The release notes name the machine it was built on. From a clean
clone at the tip of `main`:

```sh
scripts/release-local.sh --dry-run efebia-com/codex   # every step except the publication
scripts/release-local.sh efebia-com/codex             # newest stable upstream release
scripts/release-local.sh --force efebia-com/codex     # new revision of a published version
```

It does not start while a `release.yml` run is queued or in progress or while
another run holds its lock, and it checks the version again right before
publishing. Every cargo step runs with `CARGO_INCREMENTAL=0` in an emptied
target directory under `.work/release-local`; the release build runs one cargo
job at a time unless `--release-jobs` says otherwise, because the largest crates
need several GB of memory each. It never uses sudo: the musl toolchain that the
workflow installs with apt is taken from the system or set up under
`.work/release-local/cache/tools` (Debian or Ubuntu). The header of the script
lists every option and requirement.

[`scripts/release-scheduled.sh`](scripts/release-scheduled.sh) is the scheduled
run, for a timer every 30 minutes in such a clone (a systemd timer, for
example). It checks for an unpublished upstream release with no open
`release-failure` issue; when there is one, it waits for the lock, brings the
clone to the tip of `main` and runs `release-local.sh`, with the log under
`.work/release-local/logs`. A failed run opens or updates the `release-failure`
issue with the end of that log.

## Build locally

```sh
scripts/upstream-latest.sh                          # newest stable upstream tag
scripts/prepare-source.sh rust-v0.169.0 .work/src   # fetch the tag, apply patches/series
scripts/test-extensions.sh --source .work/src       # tests listed in patches/tests
scripts/build.sh --source .work/src --out .work/pkg # debug build for this machine
```

`build.sh --release --target <triple>` is the release build used by CI; the
Linux musl targets need the toolchain that the workflow installs (and that
`release-local.sh` sets up). The scripts
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
