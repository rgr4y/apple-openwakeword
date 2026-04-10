# apple-openwakeword

A fully on-device voice assistant pipeline for macOS, built around Apple's own speech stack.

## Why

Home Assistant's voice pipeline normally needs a mix of cloud services or Linux-based
satellites. If you have a Mac, you already have everything you need:

- **Wake word** — openWakeWord running locally via ONNX (no TFLite, no Pi required)
- **Speech-to-text** — Apple's on-device `SpeechAnalyzer` / `SFSpeechRecognizer` (zero latency, no API key)
- **LLM** — any Ollama-compatible local model, including Apple's own `apple-foundationmodel`
- **Text-to-speech** — macOS `say` or a Wyoming TTS server
- **Home control** — direct HA conversation API integration

The whole pipeline runs on a Mac, offline, with no cloud calls. That's the point.

## What it does

```
Mic → openWakeWord → STT window → Apple Speech → LLM/HA → say
```

1. openWakeWord listens for your wake phrase via ONNX (Python, runs locally)
2. On detection, an STT window opens and Apple's speech engine transcribes what you say
3. The transcript goes to either:
   - A local LLM via Ollama (tool-calling supported, including a `home_assistant` tool)
   - Home Assistant's conversation API directly (no LLM needed for simple commands)
4. The response is spoken aloud via `say` (or a Wyoming TTS server)
5. A completion sound plays, window closes, ready for the next wake

Audio feedback sounds play at detection (OpenOrEnable) and after the response finishes (CloseOrDisable).
Double-fire protection prevents a second wake event from interrupting an active STT window.

## Features

- **Wyoming-compatible STT server** — Home Assistant, satellites, and any Wyoming
  client can connect and get transcripts
- **Streaming partials** — sends `transcript-chunk` events during recognition, then
  a final `transcript` when the utterance ends
- **Two STT backends**, selected automatically at runtime:
  - macOS 26+ → `SpeechAnalyzer` + `SpeechTranscriber` (streaming, ultra-low latency)
  - macOS 13–25 → `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
- **openWakeWord server** (`scripts/oww_server.py`) — Wyoming-protocol wake word server using ONNX, works on macOS without TFLite
- **Local LLM via Ollama** — tool-calling with a `home_assistant` tool for device control
- **Direct HA integration** — skip the LLM and send transcripts straight to HA's conversation API
- **Wyoming TTS server** (`tts/wyoming-say.py`) — wraps macOS `say` as a Wyoming TTS provider
- **Audio cues** — `sounds/` directory, plays on wake and after response
- **Default input device tracking** — detects CoreAudio device changes and re-inits instantly
- **Double-fire guard** — ignores wake word re-triggers while an STT window is already open

## Requirements

- macOS 13.0 or later (macOS 26 recommended for best quality)
- Swift 5.9 / Xcode 15 or later
- Python 3.10+ (for openWakeWord server and optional TTS server)
- For local mic: microphone permission (System Settings → Privacy & Security → Microphone)

## Two modes

### Local-orchestrated (default) — `make run-all`

The Mac drives the full pipeline. Lowest latency, fewest round trips.

```
Mic → OWW (local) → Apple STT → LLM or HA API → say (local TTS)
```

- Wake word fires locally → STT window opens immediately
- Transcript goes to your LLM or HA's conversation API
- Response spoken via macOS `say` — no network TTS round trip
- Requires `oww.host` and `ha` (or `llm`) set in `config.json`

### HA-orchestrated — `make run-ha`

The Mac exposes three Wyoming services; Home Assistant drives everything.

```
HA Pipeline: OWW server (10400) → STT server (10300) → Gemini/LLM → TTS server (10200)
```

- HA streams audio to OWW, handles wake detection, calls STT, calls conversation agent, calls TTS
- Mac is just a dumb provider of those three services
- Configure in HA: **Settings → Voice Assistants → [your assistant]** — set Wake Word, STT, Conversation Agent, TTS to point at your Mac

Switch between them by running `make run-all` vs `make run-ha`. Both start the same three servers; the only difference is whether the Swift daemon runs with `--local-mic` (local mode) or as a plain Wyoming STT server (HA mode).

## Quick start

```bash
# 1. Build the Swift daemon
swift build -c release

# 2. Copy config
cp config.json.example config.json
# Edit config.json — set ha.host, ha.token, ha.agentId, oww.host, etc.

# 3a. Local-orchestrated mode (Mac drives everything)
make run-all

# 3b. HA-orchestrated mode (HA drives everything, Mac provides services)
make run-ha
```

## Configuration (`config.json`)

```json
{
    "language": "en",
    "stt": {
        "port": 10300,
        "windowSeconds": 6,
        "silenceWindowSeconds": 1.1,
        "minTranscriptWords": 1
    },
    "tts": { "port": 10200, "rate": 220 },
    "oww": { "host": "localhost", "port": 10400 },
    "llm": {
        "enabled": false,
        "endpoint": "http://127.0.0.1:11434",
        "model": "apple-foundationmodel",
        "systemPrompt": "..."
    },
    "ha": {
        "host": "http://homeassistant.local:8123",
        "token": "your-long-lived-token"
    }
}
```

Set `llm.enabled: true` to route transcripts through Ollama. Leave it `false` to send
directly to HA's conversation API.

## Build

```bash
swift build -c release
```

Binary lands at `.build/release/AppleSTT`.

## CLI options

```
apple-stt-wyoming [OPTIONS]

OPTIONS:
  --port, -p <PORT>     TCP port (default: 10300)
  --language, -l <LANG> Language code, e.g. en, en-US, fr (default: en)
  --local-mic           Capture local mic; print JSON transcripts to stdout
  --oww-host <HOST>     openWakeWord server host (triggers STT on wake word)
  --oww-port <PORT>     openWakeWord server port (default: 10400)
  --debug               Verbose logging to stderr
  --list-mics           Print available input devices and exit
  --help                Show help
```

## Architecture

```
openWakeWord server (Python/ONNX)
  └─ Wyoming detection event
       └─ WakeWordClient (Swift/NWConnection)
            └─ onDetection → playSound → openSTTWindow

WyomingServer (NWListener TCP)          ← Home Assistant connects here
  └─ ClientSession
       ├─ wyomingDecode()
       ├─ SpeechEngineProtocol
       │    ├─ SpeechAnalyzerEngine  (macOS 26+)
       │    └─ SFSpeechEngine        (macOS 13–25)
       └─ wyomingEncode()

Local pipeline (--local-mic + --oww-host):
  Mic → MicCapture → WakeWordClient → STT window → LLMClient / HAClient → say → playSound

AudioDeviceMonitor (CoreAudio)
  └─ fires onChange → Daemon restarts MicCapture + SpeechEngine
```

## Wyoming Protocol

| Direction | Event | Description |
|---|---|---|
| client → server | `describe` | Request service info |
| server → client | `info` | Service capabilities |
| client → server | `audio-start` | Begin audio stream |
| client → server | `audio-chunk` | PCM audio payload |
| client → server | `audio-stop` | End of utterance |
| server → client | `transcript-chunk` | Streaming partial |
| server → client | `transcript` | Final result |

Audio format: any PCM (int16, float32, uint8), any sample rate — resampled to 16 kHz mono Float32 internally.

## License

MIT
