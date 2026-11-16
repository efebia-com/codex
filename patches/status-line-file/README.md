# status-line-file: status line items written by another program

Any program can show its own fields in the TUI status line, next to the built-in items, by
writing them to a JSON file that Codex watches.

## Enabling it

Name the file and place its fields in `tui.status_line` with the `file:` prefix:

```toml
[tui]
status_line = ["model-with-reasoning", "current-dir", "file:build", "file:queue"]
status_line_file = "/run/user/1000/codex-status/{session_id}.json"
```

- `tui.status_line_file` is a path like the other paths in the config: `~` is expanded and a
  relative path is relative to the config file. `codex -c tui.status_line_file=...` sets it for
  one run.
- The `CODEX_STATUS_LINE_FILE` environment variable, when set and not empty, takes precedence; a
  relative value is relative to the directory Codex was started in.
- `{session_id}` in the path expands to the id of the session shown by the TUI: the same value
  shell commands receive as `CODEX_SESSION_ID`, the id of the session's root thread. Until a
  session exists, no file is read. When the session changes (`/new`, `/resume`, another session),
  Codex switches files and drops the values read from the previous one at once.

Without a path nothing changes: no thread is started and Codex behaves exactly as upstream.

## The file

```json
{"fields": {"build": "build ok", "queue": 3}}
```

- Field values are strings or numbers. `null`, booleans, arrays and objects hide the field.
- Keys are 1 to 64 characters among ASCII letters, digits, `_`, `-` and `.`; other keys are
  ignored. Top-level keys other than `fields` are ignored.
- Whitespace and control characters (newlines, tabs, escape sequences) become single spaces, and
  the value is trimmed; an empty value hides the field. Values wider than 48 columns are cut and
  end with `…`.
- A missing file, invalid JSON, a file without `fields` or larger than 64 KiB: the `file:` items
  are simply not shown. No warnings are printed.
- Write the file atomically (write a temporary file in the same directory, then rename it), so
  Codex never reads it half-written.

Codex checks the file's metadata twice a second from a background thread and re-reads it only
when it changes; the status line is updated in the next frame. Rendering never reads the file.

## Item ids

`file:<key>` items can be mixed and ordered freely with the built-in items. Built-in ids are
kebab-case words, so the `:` of the prefix can never collide with a current or future upstream
id. A `file:` id with an invalid key (for example `file:bad key`) is reported once as an invalid
status line item, like any other unknown id.

The `/statusline` picker lists the configured `file:` items and the fields present in the file
now, with their values in the preview, and saves them like the other items. `/statusline` with
arguments accepts them too, e.g. `/statusline model file:build`.

## Series

1. `config: add tui.status_line_file`: the config key, its JSON schema entry and its plumbing
   to the TUI settings.
2. `tui: show status line items from an external JSON file`: the `status_line_file` module
   (parsing, watcher, path resolution), the status line rendering, the picker and the
   `/statusline` command, with unit tests and `insta` snapshots.

## Tests

From `codex-rs`:

```
cargo test -p codex-tui status_line
cargo test -p codex-core config_schema_matches_fixture
```
