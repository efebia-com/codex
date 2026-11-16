# channels: MCP servers that push events into the chat

An MCP server can send events to a running Codex chat, which the model then reads and can act
on: chat messages, CI results, alerts. The protocol is the one Claude Code calls *channels*, so a
server written for one client works with the other.

## Enabling a server

The server must be configured with `channel = true` and must declare the experimental
capability `claude/channel` in its `initialize` result:

```toml
[mcp_servers.webhook]
command = "webhook-channel"
channel = true
```

or, for one run, `codex -c mcp_servers.webhook.channel=true`. Without `channel = true` nothing
changes: the server is started and initialized exactly as in upstream Codex, and any channel
notifications it sends are ignored.

With `channel = true`, Codex declares `capabilities.experimental["claude/channel"] = {}` in its own
`initialize` request to that server, so the server can tell whether its events will be shown.
Channels need a session with an `initialize` handshake (MCP 2025-11-25 and earlier); a server
spoken to with the stateless 2026-07-28 protocol is not treated as a channel.

## Events

The server sends:

```json
{"jsonrpc": "2.0", "method": "notifications/claude/channel",
 "params": {"content": "build failed on main", "meta": {"severity": "high", "run_id": "1234"}}}
```

and the model receives a user message with:

```
<channel source="webhook" run_id="1234" severity="high">
build failed on main
</channel>
```

- `source` is the server's name in the configuration.
- `meta` entries become attributes, sorted by key. Keys must consist of ASCII letters, digits and
  `_`; values must be strings of at most 1,000 characters. Other entries, and a `source` key, are
  dropped.
- `&`, `<` and `>` in the content, and also `"` in attribute values, are written as XML entities,
  so no event can close the tag or forge another one.
- A notification without a string `content`, or with more than 100,000 characters of it, is
  dropped.

The server's `instructions` reach the model as the description of its tool namespace, so a
two-way channel should expose a reply tool and explain the attributes in its instructions.

## Delivery

- An idle chat starts a turn for an event at once.
- Events that arrive during a turn wait, in order, and are delivered together as one turn when
  the chat is next idle. After an interrupted turn they wait for the next event or completed
  turn, so interrupting is not undone by a queued event.
- At most 64 events wait per chat (and per server before that); a further event is dropped and
  logged. Waiting events are lost when the chat ends.
- Events go only to the main chat. Sub-agents and other internal threads do not start channel
  servers at all, so a server never runs twice for one chat.

## Chat lifecycle

- A new chat (`/new`) starts its own instance of each channel server; the previous chat's instance
  stops when that chat shuts down. Events reach the chat whose server sent them.
- A resumed chat (`/resume`, `codex resume`) starts the servers again, and their events start
  turns as in a new chat. Events that were waiting when the chat ended are not restored.
- A channel server that exits or crashes is not started again, neither by itself nor by the next
  turn: its events stop until a new or resumed chat starts it.

## Tests

```
cargo test -p codex-rmcp-client --lib custom_notifications
cargo test -p codex-mcp --lib channel
cargo test -p codex-channels-extension
```

The last one includes `tests/lifecycle.rs`, which drives a real stdio server (needs `python3`)
through an idle chat, a new chat, a resumed chat and a server that dies.

## Not covered

- Delivery into a running turn: events wait for the turn to end.
- Permission relay (`claude/channel/permission`).
- MCP servers contributed by plugins: only servers named under `mcp_servers` in the
  configuration can be channels.
- Acknowledgement: the server learns nothing about delivery; like in Claude Code, a reply tool is
  the way to report back.
