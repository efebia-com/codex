# Minimal JSON-RPC client for `codex app-server` over stdio.

import json
import os
import queue
import subprocess
import threading
import time
from collections.abc import Callable
from pathlib import Path


class AppServerError(RuntimeError):
    pass


class AppServer:
    def __init__(self, *, codex: Path, home: Path, workdir: Path, stderr_log: Path) -> None:
        env = {
            **os.environ,
            "CODEX_HOME": str(home),
            "NO_COLOR": "1",
            # The fake model name is unknown to Codex and would warn on every request.
            "RUST_LOG": "warn,codex_models_manager::model_info=error",
        }
        self.stderr_log = stderr_log
        self.stderr_file = stderr_log.open("wb")
        # The binary under test is the harness's whole input.
        self.process = subprocess.Popen(  # noqa: S603
            [str(codex), "app-server"],
            cwd=workdir,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_file,
        )
        self.incoming: queue.Queue[dict | None] = queue.Queue()
        self.buffered: list[dict] = []
        self.next_id = 0
        threading.Thread(target=self._read_stdout, daemon=True).start()

    def _read_stdout(self) -> None:
        stdout = self.process.stdout
        if stdout is None:
            msg = "app-server stdout is not piped"
            raise AppServerError(msg)
        for line in stdout:
            if line.strip():
                self.incoming.put(json.loads(line))
        self.incoming.put(None)

    def _send(self, message: dict) -> None:
        stdin = self.process.stdin
        if stdin is None:
            msg = "app-server stdin is not piped"
            raise AppServerError(msg)
        stdin.write((json.dumps(message) + "\n").encode())
        stdin.flush()

    def _receive(self, deadline: float, description: str) -> dict:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            msg = f"timed out waiting for {description}"
            raise AppServerError(msg)
        try:
            message = self.incoming.get(timeout=remaining)
        except queue.Empty:
            msg = f"timed out waiting for {description}"
            raise AppServerError(msg) from None
        if message is None:
            code = self.process.wait()
            msg = f"app-server exited with code {code} while waiting for {description}"
            raise AppServerError(msg)
        return message

    def request(self, method: str, params: dict, *, timeout: float = 30) -> dict:
        self.next_id += 1
        request_id = self.next_id
        self._send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            message = self._receive(deadline, f"the response to {method}")
            if message.get("id") == request_id and "method" not in message:
                if "error" in message:
                    msg = f"{method} failed: {message['error']}"
                    raise AppServerError(msg)
                return message["result"]
            self.buffered.append(message)

    def notify(self, method: str, params: dict | None = None) -> None:
        message: dict = {"method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    def wait_for(self, description: str, predicate: Callable[[dict], bool], *, timeout: float = 30) -> dict:
        for index, message in enumerate(self.buffered):
            if predicate(message):
                return self.buffered.pop(index)
        deadline = time.monotonic() + timeout
        while True:
            message = self._receive(deadline, description)
            if predicate(message):
                return message
            self.buffered.append(message)

    def wait_for_notification(
        self, method: str, *, thread_id: str, timeout: float = 30, where: Callable[[dict], bool] | None = None
    ) -> dict:
        def matches(message: dict) -> bool:
            params = message.get("params") or {}
            return (
                message.get("method") == method
                and params.get("threadId") == thread_id
                and (where is None or where(params))
            )

        return self.wait_for(f"{method} on thread {thread_id}", matches, timeout=timeout)["params"]

    def close(self) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.stderr_file.close()

    def stderr_tail(self, lines: int = 40) -> str:
        text = self.stderr_log.read_text(encoding="utf-8", errors="replace")
        return "\n".join(text.splitlines()[-lines:])
