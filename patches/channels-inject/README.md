# Channel delivery during an active turn

Channel servers can opt in to delivery while the main thread is working:

```toml
[mcp_servers.events]
command = "event-server"
channel = true
channel_during_turn = true
```

`channel_during_turn` is a per-server boolean, defaults to false and is ignored without
`channel = true`. Servers with only `channel = true` keep their existing behavior: events wait
for the active turn to finish, then start a channel turn. Servers must declare the
`claude/channel` experimental capability over a protocol with an initialize handshake.
The capability is checked separately on every connection, including reconnects.

For opted-in servers, notifications become ordinary user input in the active regular turn,
using the same `<channel source="events">` format. They appear in the next model request after
pending tool results, keep their server's FIFO order, and are visible in history, the UI and
resumed threads. No additional turn starts. Notifications from other servers wait for idle.
Review, compact, finishing and other turns that reject steering use the existing idle path.

A steered batch stays in memory until the core confirms that its user message was recorded.
On interrupt, unconfirmed batches return to the head of the queue in order. Interrupt does not
restart work: they wait for a new notification, a completed turn or the next regular turn.
A normal turn completion discards unconfirmed input with a warning, so an input hook that
blocks a message cannot create a retry loop. The limit of 64 waiting events includes
unconfirmed batches. Idle delivery retains its original acceptance behavior.

Pending and unconfirmed events have no durability after process exit. A cancellation between
recording and confirmation may cause a repeat. Recorded user input follows ordinary history,
resume, rollback and compaction rules. If multi-agent mailbox policy defers model sampling to
the next turn, steered input can be recorded now and answered in the next turn. Channel input
goes only to the root thread; channel servers are not started in sub-agents.

The server receives no delivery acknowledgement. Expose a reply tool when it needs a response.
Permission relay and channels contributed by plugins remain outside this extension.

Validation commands:

```sh
cargo test -p codex-config channel_during_turn
cargo test -p codex-core --lib config::schema::tests
cargo test -p codex-rmcp-client --lib custom_notifications
cargo test -p codex-mcp --lib channel
cargo test -p codex-channels-extension
cargo test -p codex-app-server --test all mcp_channels
```

Apply this series after the base channel, channel test, MCP environment and status line series.
