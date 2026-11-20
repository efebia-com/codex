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
RESTART_STARTS = 2


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


def delivers_during_active_turn(session: Session) -> None:
    content = "active turn smoke"
    session.model.script(
        fake_model.tool_call(
            "resp-active-tool",
            call_id="call-active-emit",
            namespace="mcp__chan",
            name="emit",
            arguments={"messages": [{"content": content}]},
        )
    )
    session.model.script(fake_model.assistant_reply("resp-active-final", "tool done"))
    turn_id = session.start_turn("call the emit tool")
    session.app.wait_for_notification(
        "turn/completed", thread_id=session.thread_id, where=lambda params: params["turn"]["id"] == turn_id
    )
    session.wait_for_delivery("chan", content)
    requests = session.model.responses_requests()
    _check(len(requests) >= EMIT_TURN_REQUESTS, "active delivery must cause a tool follow-up")
    for request in requests:
        _check(
            request.get("client_metadata", {}).get("turn_id") == turn_id,
            "channel_during_turn must deliver in the original turn",
        )
    last = requests[-1]
    _check(
        [element.body for element in channel.elements(last)] == [content], "expected one channel delivery in history"
    )
    expected = f'<channel source="chan">\n{content}\n</channel>'
    _check(expected in channel.user_texts(last), f"missing exact channel input {expected!r}")
    items = last.get("input", [])
    output_index = next(
        (
            index
            for index, item in enumerate(items)
            if item.get("type") == "function_call_output" and item.get("call_id") == "call-active-emit"
        ),
        len(items),
    )
    _check(output_index < len(items), "missing output for call-active-emit")
    _check(
        expected in channel.user_texts({"input": items[output_index + 1 :]}),
        "channel input must follow the tool output",
    )


def restarts_proactively_with_same_environment(session: Session) -> None:
    server = session.servers["restart"]
    server.wait_for_records("initialized", 1)
    original = server.records("start")[0]
    server.push({"exit_pid": original["pid"]})
    # No model request or tool call drives recovery: wait for the replacement handshake.
    initialized = server.wait_for_records("initialized", 2)
    starts = server.records("start")
    _check(len(starts) == RESTART_STARTS, f"expected original and one replacement, got {starts}")
    replacement = starts[-1]
    _check(replacement["pid"] != original["pid"], "restart must use a new process")
    _check(initialized[-1]["pid"] == replacement["pid"], "replacement must complete the handshake")
    _check(not session.model.responses_requests(), "restart must happen before any model request")
    _check(replacement["env"] == original["env"], "restart must preserve the environment")
    _check(original["env"]["SMOKE_RESTART_VALUE"] == "configured", "missing configured environment")
    _check(original["env"]["CODEX_THREAD_ID"] == session.thread_id, "missing thread environment")
    _check(original["env"]["CODEX_SESSION_ID"], "missing session environment")
    session.model.script(
        fake_model.tool_call("resp-pid", call_id="call-pid", namespace="mcp__restart", name="pid", arguments={})
    )
    session.model.script(fake_model.assistant_reply("resp-restart-final", "tool done"))
    turn_id = session.start_turn("call the pid tool")
    session.app.wait_for_notification(
        "turn/completed", thread_id=session.thread_id, where=lambda params: params["turn"]["id"] == turn_id
    )
    outputs = [
        item["output"]
        for item in session.model.responses_requests()[-1].get("input", [])
        if item.get("type") == "function_call_output" and item.get("call_id") == "call-pid"
    ]
    _check(len(outputs) == 1, f"expected one pid tool result, got {outputs}")
    output = outputs[0]
    texts = [output] if isinstance(output, str) else [part.get("text", "") for part in output]
    _check(json.dumps({"pid": replacement["pid"]}) in texts, f"pid tool must run on the replacement: {texts}")
    calls = server.records("tool_call")
    _check(len(calls) == 1 and calls[0]["pid"] == replacement["pid"], f"expected one replacement call: {calls}")


CASES: list[tuple[str, list[ServerSpec], Callable[[Session], None]]] = [
    ("idle thread starts a turn with the channel message", [CHANNEL], idle_thread_starts_turn),
    ("server without opt-in is ignored", [ServerSpec("plain", channel=None), CHANNEL], ignores_server_without_opt_in),
    ("notification during a turn is delivered after it", [CHANNEL], queues_during_active_turn),
    (
        "opted-in notification is delivered during the same turn",
        [ServerSpec("chan", channel=True, channel_during_turn=True)],
        delivers_during_active_turn,
    ),
    (
        "opted-in MCP restart is proactive and preserves the environment",
        [ServerSpec("restart", channel=None, restart_on_exit=True)],
        restarts_proactively_with_same_environment,
    ),
]
