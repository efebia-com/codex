# Reads `<channel>` elements back out of the model requests Codex sent.

from dataclasses import dataclass


@dataclass(frozen=True)
class ChannelElement:
    attributes: tuple[tuple[str, str], ...]
    raw_body: str

    @property
    def body(self) -> str:
        return unescape(self.raw_body)

    def attribute(self, name: str) -> str | None:
        return next((unescape(value) for key, value in self.attributes if key == name), None)


def unescape(text: str) -> str:
    return text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&amp;", "&")


def parse(text: str) -> ChannelElement | None:
    # Expected shape: <channel source="name" key="value">\nBODY\n</channel>
    if not text.startswith("<channel"):
        return None
    rest = text.removeprefix("<channel")
    attributes: list[tuple[str, str]] = []
    while True:
        trimmed = rest.lstrip(" ")
        if trimmed.startswith(">"):
            rest = trimmed[1:]
            break
        if trimmed == rest or '="' not in trimmed:
            return None
        name, after_name = trimmed.split('="', 1)
        if '"' not in after_name:
            return None
        value, rest = after_name.split('"', 1)
        attributes.append((name, value))
    if not rest.startswith("\n") or not rest.endswith("\n</channel>"):
        return None
    return ChannelElement(tuple(attributes), rest[1 : -len("\n</channel>")])


def user_texts(request: dict) -> list[str]:
    texts = []
    for item in request.get("input", []):
        if item.get("type") != "message" or item.get("role") != "user":
            continue
        texts.extend(
            span["text"]
            for span in item.get("content", [])
            if span.get("type") == "input_text" and isinstance(span.get("text"), str)
        )
    return texts


def elements(request: dict) -> list[ChannelElement]:
    found = []
    for text in user_texts(request):
        if not text.startswith("<channel"):
            continue
        element = parse(text)
        if element is None:
            msg = f"malformed <channel> input text: {text!r}"
            raise AssertionError(msg)
        found.append(element)
    return found


def first_appearances(requests: list[dict]) -> list[tuple[int, ChannelElement]]:
    seen: list[tuple[int, ChannelElement]] = []
    for index, request in enumerate(requests):
        for element in elements(request):
            if all(known != element for _, known in seen):
                seen.append((index, element))
    return seen
