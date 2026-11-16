# Smoke cases for MCP channel notifications on a built Codex binary.

import json
import time
from collections.abc import Callable

import channel
import fake_model
from session import CHANNEL_CAPABILITY, ServerSpec, Session


CHANNEL = ServerSpec("chan", channel=True)
QUIET_SECONDS = 1.0
# The emit turn makes two model requests (the user prompt and the tool follow-up).
EMIT_TURN_REQUESTS = 2


def _check(condition: object, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def idle_thread_starts_turn(session: Session) -> None:
    capabilities = session.servers["chan"].client_capabilities()
    _check(
        capabilities.get("experimental", {}).get(CHANNEL_CAPABILITY) == {},
        f"Codex must declare experimental[{CHANNEL_CAPABILITY!r}] to a channel server; sent {capabilities}",
    )
    session.servers["chan"].push({"content": "ping 42", "meta": {"chat_id": "x", "bad-key": "y"}})

    started = session.app.wait_for_notification("turn/started", thread_id=session.thread_id)
    turn_id = started["turn"]["id"]
    session.app.wait_for_notification(
        "turn/completed", thread_id=session.thread_id, where=lambda params: params["turn"]["id"] == turn_id
    )
    index, _ = session.wait_for_delivery("chan", "ping 42")
    texts = channel.user_texts(session.model.responses_requests()[index])
    expected = '<channel source="chan" chat_id="x">\nping 42\n</channel>'
    _check(expected in texts, f"expected user input text {expected!r}; got {texts}")


def ignores_server_without_opt_in(session: Session) -> None:
    capabilities = session.servers["plain"].client_capabilities()
    _check(
        CHANNEL_CAPABILITY not in capabilities.get("experimental", {}),
        f"a server without channel = true must get the upstream initialize; got {capabilities}",
    )
    session.servers["plain"].push({"content": "ignored plain"})
    time.sleep(QUIET_SECONDS)
    session.servers["chan"].push({"content": "control"})
    session.wait_for_delivery("chan", "control")
    time.sleep(QUIET_SECONDS)
    _check(session.servers["plain"].sent() != [], "server 'plain' should have sent its notification")
    for index, request in enumerate(session.model.responses_requests()):
        _check(
            "ignored plain" not in json.dumps(request),
            f"model request #{index} contains a notification from a server without channel = true",
        )


def queues_during_active_turn(session: Session) -> None:
    session.model.script(
        fake_model.tool_call(
            "resp-tool",
            call_id="call-emit",
            namespace="mcp__chan",
            name="emit",
            arguments={"messages": [{"content": "during the turn"}]},
        )
    )
    session.model.script(fake_model.assistant_reply("resp-final", "tool done"))
    turn_id = session.start_turn("call the emit tool")
    session.app.wait_for_notification(
        "turn/completed", thread_id=session.thread_id, where=lambda params: params["turn"]["id"] == turn_id
    )
    index, _ = session.wait_for_delivery("chan", "during the turn")
    _check(
        index >= EMIT_TURN_REQUESTS,
        f"a notification received during a turn must wait for the turn to end; it reached model request #{index}",
    )
    session.app.wait_for_notification(
        "turn/started", thread_id=session.thread_id, where=lambda params: params["turn"]["id"] != turn_id
    )


CASES: list[tuple[str, list[ServerSpec], Callable[[Session], None]]] = [
    ("idle thread starts a turn with the channel message", [CHANNEL], idle_thread_starts_turn),
    ("server without opt-in is ignored", [ServerSpec("plain", channel=None), CHANNEL], ignores_server_without_opt_in),
    ("notification during a turn is delivered after it", [CHANNEL], queues_during_active_turn),
]
