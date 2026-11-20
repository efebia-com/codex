# channels-ui: channel messages in the TUI

Builds on [`channels`](../channels/README.md). The TUI shows each message that an opted-in channel
server delivers as a compact line, `← <source>` followed by the message text, instead of the raw
`<channel source="...">` input that the model receives. A call to the `send` tool of a channel server
is shown the same way, as `→ <server>` with the text sent (`<server> · sending` until the result
arrives) and its result; the full call stays available in the expanded details.

Only complete channel envelopes are rendered this way: prompts typed by the user, pasted XML and
incomplete envelopes keep their normal rendering. Without a server configured with `channel = true`
nothing changes.

Tests: `cargo test -p codex-tui --lib channel_messages`.
