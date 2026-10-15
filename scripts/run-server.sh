#!/usr/bin/env bash
# Start rustle-server (local Whisper ASR + formatter) on 127.0.0.1:8765.
# Optional: RUSTLE_LLM=claude to enable Claude polish (needs ANTHROPIC_API_KEY or `ant auth login`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/server"
VENV="$SERVER/.venv"
PY="${RUSTLE_PYTHON:-$(command -v python3.12 || command -v python3.11 || command -v python3)}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating venv with $PY"
  "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip >/dev/null
  "$VENV/bin/pip" install -r "$SERVER/requirements.txt"
fi

cd "$SERVER"
exec "$VENV/bin/python" rustle_server.py
