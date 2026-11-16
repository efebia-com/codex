# Fake MCP stdio server that pushes `notifications/claude/channel` events.
#
# Each line appended to the inbox file is a JSON object sent as the params of one channel
# notification. The `emit` tool sends notifications from inside a tool call. Startup, the
# received `initialize` params, sent notifications and tool calls are appended to the record
# file as JSON lines. Standard library only; runs on Python 3.10 or later.

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path


CHANNEL_METHOD = "notifications/claude/channel"
CHANNEL_CAPABILITY = "claude/channel"
POLL_SECONDS = 0.05
METHOD_NOT_FOUND = -32601
EMPTY_RESULTS = {
    "ping": {},
    "resources/list": {"resources": []},
    "resources/templates/list": {"resourceTemplates": []},
    "prompts/list": {"prompts": []},
}
EMIT_TOOL = {
    "name": "emit",
    "description": "Send channel notifications to the client.",
    "inputSchema": {
        "type": "object",
        "properties": {"messages": {"type": "array", "items": {"type": "object"}}},
        "required": ["messages"],
    },
    "annotations": {"readOnlyHint": True},
}


class FakeChannelServer:
    def __init__(self, *, inbox: Path, record: Path, capability: bool) -> None:
        self.inbox = inbox
        self.record = record
        self.capability = capability
        self.lock = threading.Lock()
        self.initialized = threading.Event()

    def send(self, message: dict) -> None:
        line = json.dumps({"jsonrpc": "2.0", **message}) + "\n"
        with self.lock:
            sys.stdout.write(line)
            sys.stdout.flush()

    def log(self, event: str, **fields: object) -> None:
        line = json.dumps({"event": event, **fields}) + "\n"
        with self.lock, self.record.open("a", encoding="utf-8") as record:
            record.write(line)

    def notify(self, params: object) -> None:
        self.send({"method": CHANNEL_METHOD, "params": params})
        self.log("notification", params=params)

    def initialize_result(self, params: dict) -> dict:
        capabilities: dict = {"tools": {}}
        if self.capability:
            capabilities["experimental"] = {CHANNEL_CAPABILITY: {}}
        return {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": capabilities,
            "serverInfo": {"name": "fake-channel", "version": "1"},
        }

    def call_tool(self, params: dict) -> dict:
        arguments = params.get("arguments") or {}
        self.log("tool_call", name=params.get("name"), arguments=arguments)
        messages = arguments.get("messages", [])
        for message in messages:
            self.notify(message)
        return {"content": [{"type": "text", "text": f"sent {len(messages)}"}]}

    def result_for(self, method: str, params: dict) -> dict | None:
        if method == "initialize":
            self.log("initialize", params=params)
            return self.initialize_result(params)
        if method == "tools/list":
            return {"tools": [EMIT_TOOL]}
        if method == "tools/call":
            return self.call_tool(params)
        return EMPTY_RESULTS.get(method)

    def handle(self, message: dict) -> None:
        method = message.get("method")
        if method is None:
            return
        if "id" not in message:
            if method == "notifications/initialized":
                self.initialized.set()
            return
        result = self.result_for(method, message.get("params") or {})
        if result is None:
            error = {"code": METHOD_NOT_FOUND, "message": f"method not found: {method}"}
            self.send({"id": message["id"], "error": error})
            return
        self.send({"id": message["id"], "result": result})

    def watch_inbox(self) -> None:
        self.initialized.wait()
        offset = 0
        while True:
            data = self.inbox.read_bytes() if self.inbox.exists() else b""
            end = data.rfind(b"\n", offset) + 1
            for line in data[offset:end].splitlines():
                if line.strip():
                    self.notify(json.loads(line))
            offset = max(offset, end)
            time.sleep(POLL_SECONDS)

    def serve(self) -> None:
        self.log("start", pid=os.getpid())
        threading.Thread(target=self.watch_inbox, daemon=True).start()
        for line in sys.stdin:
            if line.strip():
                self.handle(json.loads(line))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inbox", type=Path, required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--no-capability", action="store_true")
    args = parser.parse_args()
    server = FakeChannelServer(inbox=args.inbox, record=args.record, capability=not args.no_capability)
    server.serve()


if __name__ == "__main__":
    main()
