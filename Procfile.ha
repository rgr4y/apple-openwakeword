# HA-orchestrated mode: Mac provides wake word + STT + TTS + satellite.
# HA drives the full pipeline: satellite mic → OWW → STT → conversation → TTS.
# After starting, add the satellite in HA: Settings → Devices → Wyoming Protocol → mac-ip:10700
oww:       bash scripts/run-oww-local.sh
tts:       bash scripts/run-tts-local.sh
stt:       .build/release/AppleSTT --ha-mode
satellite: bash scripts/run-satellite.sh
