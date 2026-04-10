#!/usr/bin/env bash
set -euo pipefail

VENV=".oww-venv"
SATELLITE_PORT="${SATELLITE_PORT:-10700}"
SATELLITE_NAME="${SATELLITE_NAME:-mac-satellite}"
WAKE_WORD="${WAKE_WORD:-alexa}"
HA_PIPELINE="${HA_PIPELINE:-}"  # optional: pipeline name shown in HA

# Ensure venv exists (shares the OWW venv)
if [[ ! -d "$VENV" ]]; then
    echo "==> Creating venv at $VENV"
    python3 -m venv "$VENV"
fi

# Install wyoming-satellite if needed
if ! "$VENV/bin/pip" show wyoming-satellite &>/dev/null; then
    echo "==> Installing wyoming-satellite"
    "$VENV/bin/pip" install --quiet -r satellite/requirements.txt
fi

# Mic capture via sox: 16kHz mono int16 raw PCM to stdout
MIC_CMD="sox -d --no-show-progress -r 16000 -c 1 -b 16 -e signed-integer -t raw -"

echo "==> Waiting for OWW server to be ready..."
sleep 3

echo "==> Starting Wyoming satellite — name=$SATELLITE_NAME port=$SATELLITE_PORT wake=$WAKE_WORD"

exec "$VENV/bin/python" -m wyoming_satellite.__main__ \
    --name "$SATELLITE_NAME" \
    --uri "tcp://0.0.0.0:${SATELLITE_PORT}" \
    --mic-command "$MIC_CMD" \
    --wake-uri "tcp://localhost:10400" \
    --wake-word-name "$WAKE_WORD" \
    --no-zeroconf \
    ${HA_PIPELINE:+--pipeline "$HA_PIPELINE"}
