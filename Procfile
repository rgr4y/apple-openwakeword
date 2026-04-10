# Local-orchestrated mode (default): Mac handles wake→STT→LLM/HA→TTS locally.
# Fast, fewest round trips. Requires oww.host + ha/llm in config.json.
# To use HA-orchestrated mode instead: make run-ha
oww: bash scripts/run-oww-local.sh
tts: bash scripts/run-tts-local.sh
stt: .build/release/AppleSTT --local-mic
