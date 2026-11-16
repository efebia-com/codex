# Smoke test of MCP channel notifications against a built `codex` binary.
# Offline: the model is a local fake and the MCP servers are local Python processes.

import argparse
import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

from app_server import AppServerError
from cases import CASES
from fake_model import FakeModel
from session import ServerSpec, Session


CHANNEL_SETTING = "`mcp_servers.<name>.channel`"
# Codex logs unknown config.toml keys as "`mcp_servers.<name>.channel` is ignored".
CHANNEL_SETTING_IGNORED = re.compile(r"`mcp_servers\.[^`]+\.channel` is ignored")


def run_case(codex: Path, name: str, specs: list[ServerSpec], case: Callable[[Session], None]) -> bool:
    with tempfile.TemporaryDirectory(prefix="codex-channels-") as tmp, FakeModel().running() as model:
        session = Session(codex=codex, root=Path(tmp), model=model, specs=specs)
        failure = None
        try:
            session.start()
            case(session)
        except (AssertionError, AppServerError) as error:
            failure = str(error)
        finally:
            session.close()
        if failure is not None:
            _report_failure(name, failure, session, model)
            return False
    sys.stdout.write(f"PASS  {name}\n")
    return True


def _report_failure(name: str, reason: str, session: Session, model: FakeModel) -> None:
    lines = [f"FAIL  {name}", *(f"      {line}" for line in reason.splitlines())]
    if model.unexpected:
        lines.append(f"      unexpected requests to the fake model: {model.unexpected}")
    stderr = session.app.stderr_tail()
    if CHANNEL_SETTING_IGNORED.search(session.app.stderr_log.read_text(encoding="utf-8", errors="replace")):
        lines.append(f"      hint: this codex ignores {CHANNEL_SETTING}: it was built without the channels extension")
    lines.append("      --- codex stderr (last lines) ---")
    lines.extend(f"      {line}" for line in stderr.splitlines())
    sys.stdout.write("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Smoke test of MCP channel notifications.")
    parser.add_argument("codex", type=Path, help="path to the codex binary under test")
    args = parser.parse_args()
    codex = args.codex.resolve()
    if not os.access(codex, os.X_OK):
        sys.exit(f"not an executable file: {codex}")
    # The binary under test is the harness's whole input.
    version = subprocess.run(  # noqa: S603
        [codex, "--version"], capture_output=True, text=True, check=True, timeout=60
    )
    sys.stdout.write(f"codex under test: {codex} ({version.stdout.strip()})\n")
    results = [run_case(codex, name, specs, case) for name, specs, case in CASES]
    failed = results.count(False)
    sys.stdout.write(f"{len(results) - failed} passed, {failed} failed\n")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
