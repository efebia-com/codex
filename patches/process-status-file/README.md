# process-status-file: which conversation each Codex process shows

While the TUI runs, Codex keeps a small JSON file per process that tells which conversation the
process shows, where, and whether a turn is running in it. Another program can then map a process
or a tmux pane to its conversation without wrappers, hooks or reading the screen.

It is always on. It changes nothing in what Codex does or shows.

## The file

`$CODEX_HOME/processes/<pid>.json` (by default `~/.codex/processes/<pid>.json`):

```json
{"pid":1187880,"procStart":"241526951","sessionId":"019a…","cwd":"/home/me/project",
 "tmux":"work:@1855.%1856","status":"idle","kind":"interactive","version":"0.169.1",
 "startedAt":1794990769979,"updatedAt":1795000025853,"statusUpdatedAt":1795000025853}
```

The field names are the ones Claude Code uses in `~/.claude/sessions/<pid>.json`, so one reader
can handle both.

- `pid`: the process id.
- `procStart`: the process start time in clock ticks after boot, field 22 of `/proc/<pid>/stat`,
  as a string. Together with `pid` it names one process even after the pid is reused. `null`
  where `/proc` does not exist.
- `sessionId`: the id of the conversation shown, the root thread (the same value shell commands
  get as `CODEX_SESSION_ID`). `null` before a conversation exists (startup screens, pickers).
- `cwd`: the working directory of the conversation shown.
- `tmux`: `session:@window.%pane` of the process's pane, as `tmux display-message` prints it; only
  `%pane` if tmux does not answer; `null` outside tmux. Looked up once at start.
- `status`: `busy` while a turn runs in the conversation shown, `idle` otherwise.
- `kind`: always `interactive` (the TUI).
- `version`: the Codex version.
- `startedAt`, `updatedAt`, `statusUpdatedAt`: milliseconds since the Unix epoch; when the file was
  first written, last changed, and when `status` last changed.

## When it changes

- At start, before any conversation, with `sessionId` null.
- When the conversation shown changes: `/new`, `/clear`, `/resume`, `/fork` (the fork is shown),
  and the first conversation once it starts. A `/side` chat, a sub-agent opened from the agents
  view, and helper threads such as summaries do not change it: they are not the conversation of
  the window.
- When its working directory changes.
- When a turn starts or ends in the conversation shown.

Nothing else rewrites it. Each write goes to `.<pid>.json.tmp` in the same directory and is then
renamed, so readers never see half a file. The directory is created with mode 0700 and the file
with 0600. Write errors are ignored: the file is a hint, never a reason to stop Codex.

## End of the process

The file is removed when the TUI exits, also after an error or a panic that ends it. A process
that is killed (SIGKILL, out of memory, or a terminal or tmux window closed under it, which sends
SIGHUP) cannot remove it. The next Codex that starts removes such files: those whose pid no longer
runs, or now belongs to a process with another start time. Readers must still check that `pid`
runs with the same `procStart` before trusting a file.

## Turning it off

```sh
CODEX_PROCESS_STATUS_FILE=0 codex
```

`0`, `false`, `off` or `no` (any case) turn it off for that process: no file is written and no
other one is removed. Any other value, or no variable, leaves it on.

## Series

- `0001` adds the `codex-process-status-file` crate: the file, its writes, the sweep of files left
  by killed processes, and its unit tests. It depends only on `serde_json`.
- `0002` connects it to the TUI in three places: the guard around `App::run` writes the file and
  removes it at exit; each frame reports the root thread shown and its working directory; thread
  status notifications report turns starting and ending. The TUI writes nothing more than that.

Tests: `cargo test -p codex-process-status-file`.
