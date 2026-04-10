# HA-orchestrated mode: Mac provides wake word + STT + TTS servers.
# HA drives the full pipeline: wake → STT → conversation agent → TTS.
# No local mic capture or LLM calls on the Mac side.
# In HA: Settings → Voice Assistants → configure all four services.
oww: bash scripts/run-oww-local.sh
tts: bash scripts/run-tts-local.sh
stt: .build/release/AppleSTT
