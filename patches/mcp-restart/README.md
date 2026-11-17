# Restart exited stdio MCP servers

Apply these two patches after channels-inject through `3520f1ce49`.
Source commits: `9617ed49b2` (implementation and unit tests), `712d443bc8` (integration tests).

```toml
[mcp_servers.example]
command = "example-mcp-server"
restart_on_exit = true
```

The option is disabled by default and applies only to stdio transports. HTTP transports ignore
it with a warning. An opted-in connection remains private and never negotiates a pooled lease.
Changing this option requires a fresh connection during the next runtime refresh.

After a connection that initialized successfully closes, the same client proactively launches
up to three replacements, with delays of 1, 2 and 4 seconds. Each attempt uses the normal startup
timeout. The budget resets after a process stays up for 60 seconds. Successfully initialized
processes that exit sooner still consume that budget.

A request already sent when the connection closes fails and is not replayed. Later requests
wait for recovery, up to the startup timeout. Exhaustion produces a warning and the call error
`MCP server exited and was not restarted after 3 attempts: <last error>`. A normal MCP refresh
can subsequently create a new connection. No additional UI events are emitted.

Replacements reuse the first launch's arguments, working directory and host-resolved environment,
including requested session/thread ids. Executor-owned variables follow the executor's policy.
The previous process is terminated and its cleanup awaited before a replacement starts. Refresh,
shutdown and release of the connection owner cancel the supervisor, its backoff and its handshake.
Local Windows servers require process containment to support awaited restart cleanup.

Every replacement passes through the usual initialize and notification capture. The preceding
channels-inject series checks channel capabilities again for each connection and fails closed
when they disappear. The tool catalog revision changes after a successful restart.

Targeted checks (run in the integrated source tree):

```sh
cargo test -p codex-rmcp-client --test stdio_restart
cargo test -p codex-rmcp-client --lib stdio_restart::
cargo test -p codex-mcp --lib restart::
cargo test -p codex-mcp --lib changing_restart_policy_requires_a_new_connection
cargo test -p codex-rmcp-client --test process_group_cleanup
cargo test -p codex-rmcp-client --test mcp_2026_stdio_discovery
cargo test -p codex-rmcp-client --test mcp_2026_stdio
cargo test -p codex-core --lib config::schema::tests
```

The app-server mcp-restart-tests series follows these patches and covers turn recovery, delivery,
capability loss, shutdown, environment identity and sub-agent ownership.
