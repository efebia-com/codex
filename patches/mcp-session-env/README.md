# mcp-session-env: chat identity for stdio MCP servers

A stdio MCP server can ask Codex which chat started it. Codex then sets the two variables it
already gives shell commands, with the same values:

- `CODEX_SESSION_ID`: the root chat. Sub-agents share it with the chat that spawned them.
- `CODEX_THREAD_ID`: the thread that started this server process.

## Enabling a server

List the variables in `env_vars` with `source = "codex"`:

```toml
[mcp_servers.notes]
command = "notes-server"
env_vars = [
  { name = "CODEX_SESSION_ID", source = "codex" },
  { name = "CODEX_THREAD_ID", source = "codex" },
]
```

`codex` joins the existing sources `local` (the Codex process environment) and `remote` (the
executor environment), and is accepted only for these two names; any other name is a
configuration error. Without such an entry nothing changes: as in upstream Codex, the server gets
the default variables, its `env` and the other `env_vars` it lists.

- The values are never read from the environment of the Codex process, which may hold another
  chat's ids when Codex is started from a Codex shell. An `env` entry with the same name is
  overridden.
- Local and executor (remote) stdio servers both receive them.
- `codex doctor` does not report them as missing variables.

## Values

The server sees the ids of the thread whose MCP runtime starts it:

- A new chat (`codex`, `codex exec`, `/new`, app-server `thread/start`): a new thread id, and a
  session id equal to it.
- A resumed chat (`codex resume`, `/resume`, `codex exec resume`, app-server `thread/resume`):
  the chat keeps its ids, and the servers it starts again see the same values as before.
- A sub-agent that starts its own instance of the server: the root chat's session id and the
  sub-agent's own thread id. Sub-agents start a server whose tool list is already cached only
  when one of its tools is called.
- A server started outside any thread, for example to list servers or their status: neither
  variable.

Codex can share one stdio server process between chats when it speaks MCP 2026-07-28 and allows
it. A server that requests these variables is never shared between threads with different ids.

The ids are informational: like for shell commands, nothing stops another process from setting
the same variables.

## Tests

```
cargo test -p codex-config --lib mcp_codex_env
cargo test -p codex-rmcp-client --lib codex_source
cargo test -p codex-mcp --lib session_env
cargo test -p codex-core --test all mcp_session_env
cargo test -p codex-core --lib config::schema_tests
```

`mcp_session_env` drives a stdio server written in Python (needs `python3`) through a chat that
is resumed and a chat that spawns a sub-agent. The last command checks the regenerated
`config.schema.json`.

## Not covered

- Streamable HTTP servers: `env_vars` does not apply to them, and no header carries the ids.
- `CODEX_VERSION` and the other variables that shell commands receive.
