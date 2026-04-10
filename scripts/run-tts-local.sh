#!/usr/bin/env bash
# Run wyoming-say.py locally, creating tts/.venv on first run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TTS_DIR="$ROOT/tts"
VENV="$TTS_DIR/.venv"

# One-time setup
if [[ ! -d "$VENV" ]]; then
  echo "==> Creating TTS venv at $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  echo "==> Installing wyoming dependencies"
  "$VENV/bin/pip" install --quiet -r "$TTS_DIR/requirements.txt"
fi

echo "==> Starting wyoming-say TTS server"
exec "$VENV/bin/python" "$TTS_DIR/wyoming-say.py" "$@"
