#!/usr/bin/env bash
# Smoke test of MCP channel notifications on a built Codex binary.
# Usage: tests/e2e/run.sh <path to bin/codex>
# Needs python3 >= 3.10 (standard library only); no network and no credentials.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <path to bin/codex>" >&2
    exit 2
fi
exec python3 -E -s "$(dirname "$0")/src/main.py" "$1"
