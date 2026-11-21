# status-line-compact

Set `tui.status_line_style = "compact"` to use compact formatting and a fixed 256-color
palette for the built-in status line. The default style is `"default"`.
Use `tui.status_line_use_colors = false` to render without the palette.

## Configuration

```toml
[tui]
status_line_style = "compact"
status_line = [
    "last-response-time",
    "model-with-reasoning",
    "context-remaining",
    "current-dir",
    "five-hour-limit",
    "weekly-limit",
    "file:label",
    "file:aliases",
    "session-id",
]
status_line_file = "~/.cache/codex-status/{session_id}.json"
```

For the external items, a program can write the following JSON using the mechanism described in
[status-line-file](../status-line-file/README.md).

```json
{"fields": {"label": "example", "aliases": "⚓ example-fixed"}}
```

The resulting line can look like this.

```text
20:44:Sat │ Example Model/max │ 86.0% │ ~/projects │ 5h:? │ 7d:63% (4d13h) │ example │ ⚓ example-fixed │ 2f025ba0-1234-4321-8765-001122334455
```

- `last-response-time` works with either style. It shows local turn completion time as
  `HH:MM:Day` with an English weekday abbreviation. Completed, interrupted and failed turns
  all count. For a live completion without a timestamp, the TUI uses the time it received the
  event. A resumed session uses the latest saved completion with a timestamp. The field is
  omitted until a timestamp is available.
- Compact layout renders model and effort as `model/effort` and context remaining with
  one decimal place. Local working directories under the user's home start with `~`.
- `5h` and `7d` show the remaining percentage or `?` when the corresponding window is
  unavailable. When 30% or less remains in the 5-hour window and the reset time is available,
  `5h` includes the local reset time. A known weekly percentage includes the time until
  reset, or `(?)` when the reset time is unavailable.
- External fields and the session ID are violet. The external program supplies the field
  text, including any symbols. Unavailable external fields are omitted.
- The `/statusline` picker lists `last-response-time` and previews the configured style.

## Series

1. `config: add a compact status line style` adds the TUI setting, schema and config tests.
2. `tui: render compact status lines and show last turn time` adds the renderer, turn lifecycle
   tracking, picker preview, unit tests and Insta snapshots.

Apply after `status-line-file`, which supplies the external fields.

## Tests

Run from `codex-rs`.

```sh
cargo test -p codex-tui status_line
cargo test -p codex-core --lib config::schema::tests
cargo test -p codex-core --lib config_toml_deserializes_status_line_style
```
