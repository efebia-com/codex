# One isolated Codex app-server with its own CODEX_HOME, fake MCP servers and fake model.

import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import channel
from app_server import AppServer
from fake_model import FakeModel


CHANNEL_CAPABILITY = "claude/channel"
FAKE_SERVER_SCRIPT = Path(__file__).with_name("fake_mcp_server.py")
POLL_SECONDS = 0.05
DELIVERY_TIMEOUT = 30.0


@dataclass(frozen=True)
class ServerSpec:
    name: str
    channel: bool | None  # None leaves `channel` out of the config
    capability: bool = True


@dataclass(frozen=True)
class FakeServer:
    name: str
    inbox: Path
    record: Path

    def push(self, *params: dict) -> None:
        # A single write, so the server never reads half of a batch.
        with self.inbox.open("a", encoding="utf-8") as inbox:
            inbox.write("".join(json.dumps(item) + "\n" for item in params))

    def records(self, event: str) -> list[dict]:
        if not self.record.exists():
            return []
        lines = self.record.read_text(encoding="utf-8").splitlines()
        return [record for record in map(json.loads, lines) if record["event"] == event]

    def sent(self) -> list[dict]:
        return [record["params"] for record in self.records("notification")]

    def client_capabilities(self) -> dict:
        initialize = self.records("initialize")
        if not initialize:
            msg = f"MCP server {self.name!r} never received initialize"
            raise AssertionError(msg)
        return initialize[0]["params"].get("capabilities", {})


def _server_toml(spec: ServerSpec, server: FakeServer) -> str:
    args = [str(FAKE_SERVER_SCRIPT), "--inbox", str(server.inbox), "--record", str(server.record)]
    if not spec.capability:
        args.append("--no-capability")
    # JSON strings and string arrays are valid TOML basic strings and inline arrays.
    lines = [
        f"[mcp_servers.{spec.name}]",
        f"command = {json.dumps(sys.executable)}",
        f"args = {json.dumps(args)}",
        "startup_timeout_sec = 30",
        'default_tools_approval_mode = "approve"',
    ]
    if spec.channel is not None:
        lines.append(f"channel = {json.dumps(spec.channel)}")
    return "\n".join(lines) + "\n"


def write_config(home: Path, *, model_url: str, servers: list[str]) -> None:
    config = f"""model = "mock-model"
model_provider = "mock"
approval_policy = "never"
sandbox_mode = "read-only"
check_for_update_on_startup = false

# Plugins would sync the curated marketplace from GitHub at startup; the test stays offline.
[features]
plugins = false
tool_suggest = false
recommended_plugins = false

[model_providers.mock]
name = "Local fake model"
base_url = {json.dumps(model_url)}
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false

"""
    (home / "config.toml").write_text(config + "\n".join(servers), encoding="utf-8")


class Session:
    def __init__(self, *, codex: Path, root: Path, model: FakeModel, specs: list[ServerSpec]) -> None:
        self.model = model
        home = root / "codex-home"
        workdir = root / "workspace"
        home.mkdir()
        workdir.mkdir()
        self.servers: dict[str, FakeServer] = {}
        server_configs = []
        for spec in specs:
            server = FakeServer(spec.name, root / f"{spec.name}.inbox", root / f"{spec.name}.record")
            self.servers[spec.name] = server
            server_configs.append(_server_toml(spec, server))
        write_config(home, model_url=model.base_url, servers=server_configs)
        self.app = AppServer(codex=codex, home=home, workdir=workdir, stderr_log=root / "codex-stderr.log")
        self.thread_id = ""
        self.specs = specs

    def start(self) -> None:
        self.app.request(
            "initialize",
            {"clientInfo": {"name": "channels-smoke", "version": "1"}, "capabilities": {"experimentalApi": True}},
        )
        self.app.notify("initialized")
        result = self.app.request("thread/start", {"model": "mock-model"})
        self.thread_id = result["thread"]["id"]
        for spec in self.specs:
            self.app.wait_for(
                f"MCP server {spec.name!r} ready",
                lambda message, name=spec.name: (
                    message.get("method") == "mcpServer/startupStatus/updated"
                    and message["params"].get("name") == name
                    and message["params"].get("status") == "ready"
                ),
            )

    def start_turn(self, text: str) -> str:
        result = self.app.request("turn/start", {"threadId": self.thread_id, "input": [{"type": "text", "text": text}]})
        return result["turn"]["id"]

    def wait_for_delivery(self, server: str, content: str) -> tuple[int, channel.ChannelElement]:
        deadline = time.monotonic() + DELIVERY_TIMEOUT
        while True:
            delivered = channel.first_appearances(self.model.responses_requests())
            for index, element in delivered:
                if element.body == content:
                    return index, element
            if time.monotonic() >= deadline:
                bodies = [element.body for _, element in delivered]
                msg = (
                    f"no model request carried a <channel> element with body {content!r} "
                    f"within {DELIVERY_TIMEOUT:.0f}s\n"
                    f"  MCP server {server!r} sent: {self.servers[server].sent()}\n"
                    f"  model requests received: {len(self.model.responses_requests())}\n"
                    f"  <channel> bodies seen: {bodies}"
                )
                raise AssertionError(msg)
            time.sleep(POLL_SECONDS)

    def close(self) -> None:
        self.app.close()
