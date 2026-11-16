# Local stand-in for the Responses API: records every request and streams scripted SSE turns.

import json
import threading
from collections.abc import Generator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def sse(events: list[dict]) -> bytes:
    return "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()


def assistant_reply(response_id: str, text: str) -> list[dict]:
    message = {
        "type": "message",
        "role": "assistant",
        "id": f"msg-{response_id}",
        "content": [{"type": "output_text", "text": text}],
    }
    return _response(response_id, [message])


def tool_call(response_id: str, *, call_id: str, namespace: str, name: str, arguments: dict) -> list[dict]:
    call = {
        "type": "function_call",
        "call_id": call_id,
        "namespace": namespace,
        "name": name,
        "arguments": json.dumps(arguments),
    }
    return _response(response_id, [call])


def _response(response_id: str, items: list[dict]) -> list[dict]:
    usage = {
        "input_tokens": 0,
        "input_tokens_details": None,
        "output_tokens": 0,
        "output_tokens_details": None,
        "total_tokens": 0,
    }
    return [
        {"type": "response.created", "response": {"id": response_id}},
        *({"type": "response.output_item.done", "item": item} for item in items),
        {"type": "response.completed", "response": {"id": response_id, "usage": usage}},
    ]


class FakeModel:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[dict] = []
        self.unexpected: list[str] = []
        self.scripted: list[list[dict]] = []
        self.default_count = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler_class())

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}/v1"

    def script(self, events: list[dict]) -> None:
        with self.lock:
            self.scripted.append(events)

    def responses_requests(self) -> list[dict]:
        with self.lock:
            return list(self.requests)

    def next_turn(self, request: dict) -> bytes:
        with self.lock:
            self.requests.append(request)
            if self.scripted:
                return sse(self.scripted.pop(0))
            self.default_count += 1
            return sse(assistant_reply(f"default-{self.default_count}", "ok"))

    def record_unexpected(self, description: str) -> None:
        with self.lock:
            self.unexpected.append(description)

    @contextmanager
    def running(self) -> Generator["FakeModel", None, None]:
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        try:
            yield self
        finally:
            self.server.shutdown()
            self.server.server_close()
            thread.join()

    def _handler_class(self) -> type[BaseHTTPRequestHandler]:
        model = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if self.path.split("?")[0].endswith("/models"):
                    self._reply(200, "application/json", b'{"models": []}')
                    return
                model.record_unexpected(f"GET {self.path}")
                self._reply(404, "text/plain", b"not found")

            def do_POST(self) -> None:
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if not self.path.endswith("/responses"):
                    model.record_unexpected(f"POST {self.path}")
                    self._reply(404, "text/plain", b"not found")
                    return
                encoding = self.headers.get("Content-Encoding")
                if encoding:
                    model.record_unexpected(f"POST {self.path} with Content-Encoding {encoding}")
                    self._reply(400, "text/plain", b"compressed request bodies are not supported")
                    return
                self._reply(200, "text/event-stream", model.next_turn(json.loads(body)))

            def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
                pass

            def _reply(self, status: int, content_type: str, body: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        return Handler
