#!/usr/bin/env bash
# Run openwakeword locally (no Docker) using a venv in .oww-venv/
# Uses openwakeword + onnxruntime directly (tflite not available on macOS).
# Usage: ./scripts/run-oww-local.sh [--port 10400] [--model alexa]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
VENV="$ROOT/.oww-venv"
PORT="${OWW_PORT:-10400}"
MODEL="${OWW_MODEL:-alexa}"
SETUP_ONLY=false

# Parse args (override env)
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)       PORT="$2";  shift 2 ;;
    --model)      MODEL="$2"; shift 2 ;;
    --setup-only) SETUP_ONLY=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Pick the best available Python (prefer 3.12, fallback to 3.11, then 3.10, then python3)
PYTHON=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" &>/dev/null; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "ERROR: no suitable Python found (need 3.10+)"; exit 1
fi
echo "==> Using Python: $PYTHON ($($PYTHON --version))"

# One-time setup
if [[ ! -d "$VENV" ]]; then
  echo "==> Creating venv at $VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  echo "==> Installing openwakeword + onnxruntime + honcho (macOS-compatible)"
  "$VENV/bin/pip" install --quiet openwakeword onnxruntime wyoming honcho
fi

[[ "$SETUP_ONLY" == "true" ]] && { echo "==> Setup complete"; exit 0; }

echo "==> Starting openwakeword Wyoming server — model=$MODEL port=$PORT"

exec "$VENV/bin/python" "$SCRIPT_DIR/oww_server.py" \
  --port "$PORT" \
  --model "$MODEL"
