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

A batch stays in memory until the core confirms that its user message was recorded. This
holds for batches steered into an active turn and for batches that start their own turn when
the thread is idle, including the idle fallback when `channel_during_turn = true`. On
interrupt, unconfirmed batches return to the head of the queue in order. A batch whose turn
was cancelled before it started returns when the next regular turn starts. Interrupt does not
restart work: they wait for a new notification, a completed turn or the next regular turn.
A normal turn completion discards unconfirmed input with a warning, so an input hook that
blocks a message cannot create a retry loop. The limit of 64 waiting events includes
unconfirmed batches.

Pending and unconfirmed events have no durability after process exit. A cancellation between
recording and confirmation may cause a repeat. Recorded user input follows ordinary history,
resume, rollback and compaction rules. If multi-agent mailbox policy defers model sampling to
the next turn, steered input can be recorded now and answered in the next turn. Channel input
goes only to the root thread; channel servers are not started in sub-agents.

The server receives no delivery acknowledgement. Expose a reply tool when it needs a response.
Permission relay and channels contributed by plugins remain outside this extension.

## Input barrier

A host can stop channel input before it captures a thread, with the app-server requests
`thread/channels/fence`, `thread/channels/read` and `thread/channels/release` (experimental).
While the barrier is closed nothing reaches the model; user turns, steering and thread reads
work as usual.

Closing asks every channel server that declares the `channel/fence` experimental capability to
stop accepting input. The server answers the `channel/fence` request `{closed, token}` after it
has emitted every input it accepted before, followed by a marker: a channel notification with
empty content and `meta.fence` set to the token. A marker is never shown to the model. Every
`initialize` carries the current state as `experimental["channel/fence"] = {closed, token}`,
so a server that restarts while the barrier is closed starts closed.

Input that reaches the thread while the barrier is closed is held in order, with a sequence
number. Input already handed to a turn stays in flight until recorded; if the turn does not
record it, it is held too. A read reports the held and in-flight input, each server's
connection and fence state, what still blocks the drain and what may have been lost:
a connection that ended before its marker, input after a marker, or drops since closing.
The barrier is drained when it is closed and nothing blocks it. The host then keeps the held
input and releases it up to a sequence number, or opens the barrier: opening drops the held
input it lists as discarded and delivers the rest in order. Opening an open barrier succeeds,
with no effect, only as a retry of its last opening, so a host whose fence was lost, for
example by a restart, gets an error.

Held input lives in memory: it is lost if the process exits or the thread stops first.

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
