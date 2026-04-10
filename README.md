# apple-openwakeword

A fully on-device voice assistant pipeline for macOS, built around Apple's own speech stack. Runs in two modes: **local-orchestrated** (Mac drives everything) or **HA-orchestrated** (Mac provides Wyoming services, HA drives the pipeline).

## Why

Home Assistant's voice pipeline normally needs a mix of cloud services or Linux-based
satellites. If you have a Mac, you already have everything you need:

- **Wake word** — openWakeWord running locally via ONNX (no TFLite, no Pi required)
- **Speech-to-text** — Apple's on-device `SpeechAnalyzer` / `SFSpeechRecognizer` (zero latency, no API key)
- **LLM** — any Ollama-compatible local model, including Apple's own `apple-foundationmodel`
- **Text-to-speech** — macOS `say` wrapped as a Wyoming TTS server
- **Home control** — direct HA conversation API or local LLM with `home_assistant` tool

The whole pipeline runs on a Mac, offline. That's the point.

## Two modes

### Local-orchestrated — `make run-all`

The Mac drives the full pipeline. Lowest latency, no HA involvement in the hot path.

```
Mic → OWW (10400) → Apple STT (10300) → LLM or HA API → say
```

1. openWakeWord listens for your wake phrase via ONNX
2. On detection, an STT window opens and Apple Speech transcribes what you say
3. Transcript goes to a local LLM (tool-calling, including `home_assistant`) or HA's conversation API directly
4. Response spoken via macOS `say` — no network TTS round trip
5. Completion sound plays, window closes, ready for the next wake

Requires `oww.host` and `ha` (or `llm`) set in `config.json`.

### HA-orchestrated — `make run-ha`

The Mac exposes four Wyoming services; Home Assistant drives the full pipeline.

```
HA → Satellite (10700) → OWW (10400) → STT (10300) → Conversation agent → TTS (10200) → Satellite
```

- `wyoming-satellite` streams the Mac mic to HA and handles audio playback
- HA wakes on OWW, transcribes via Apple STT, calls its conversation agent, responds via TTS
- Mac is a provider of services — no local LLM or `say` calls
- After `make run-ha`, add the satellite in HA: **Settings → Devices & Services → Add Integration → Wyoming Protocol → `mac-ip:10700`**

You do not need to configure `oww.host` or `llm` in `config.json` for this mode.

## Features

- **Wyoming-compatible STT server** (port 10300) — HA, satellites, and any Wyoming client connect here
- **Streaming partials** — sends `transcript-chunk` events during recognition, then a final `transcript`
- **Two STT backends**, selected automatically:
  - macOS 26+ → `SpeechAnalyzer` + `SpeechTranscriber` (streaming, ultra-low latency)
  - macOS 13–25 → `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
- **openWakeWord server** (`scripts/oww_server.py`, port 10400) — Wyoming-protocol wake word server via ONNX, no TFLite needed
- **Wyoming TTS server** (`tts/wyoming-say.py`, port 10200) — wraps macOS `say` as a Wyoming TTS provider
- **Wyoming satellite** (`scripts/run-satellite.sh`, port 10700) — streams Mac mic to HA in HA-orchestrated mode
- **Local LLM** — tool-calling via any Ollama-compatible endpoint, `home_assistant` and `get_time` tools built in
- **Direct HA integration** — skip the LLM and send transcripts straight to HA's conversation API
- **Audio cues** — plays sounds at wake detection and after response completes
- **Default input device tracking** — detects CoreAudio device changes and re-initialises instantly
- **Double-fire guard** — ignores wake word re-triggers while an STT window is already open
- **Debug logging** — set `"debug": true` in `config.json` or pass `--debug` to see protocol-level detail

## Requirements

- macOS 13.0 or later (macOS 26 recommended for best STT quality)
- Swift 5.9 / Xcode 15 or later
- Python 3.10+ (for OWW server, TTS server, and satellite)
- Microphone permission: System Settings → Privacy & Security → Microphone

## Quick start

```bash
# 1. Build the Swift daemon
swift build -c release

# 2. Copy and edit config
cp config.json.example config.json
# Set ha.host, ha.token, and (for local mode) oww.host

# 3a. Local-orchestrated — Mac drives everything
make run-all

# 3b. HA-orchestrated — Mac provides services, HA drives the pipeline
make run-ha
# Then in HA: Settings → Devices & Services → Wyoming Protocol → mac-ip:10700
```

## Configuration (`config.json`)

```json
{
    "language": "en",
    "debug": false,
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
        "token": "your-long-lived-token",
        "agentId": "conversation.google_generative_ai_conversation"
    }
}
```

- `debug: true` — enables verbose protocol-level logging (audio chunks, partial transcripts, tool calls, etc.)
- `ha.agentId` — optional; routes HA conversation API calls to a specific agent (e.g. Google AI, GPT-4o). Omit to use HA's default built-in agent.
- `llm.enabled: true` — route transcripts through a local Ollama model instead of sending directly to HA.

## Build

```bash
swift build -c release
```

Binary lands at `.build/release/AppleSTT`.

## CLI options

```
AppleSTT [OPTIONS]

OPTIONS:
  --port, -p <PORT>       Wyoming STT server port (default: 10300)
  --language, -l <LANG>   Language code, e.g. en, en-US, fr (default: en)
  --local-mic             Capture local mic; drive full local pipeline
  --ha-mode               Wyoming STT server only; no local mic or LLM
  --oww-host <HOST>       openWakeWord server host (triggers STT on wake)
  --oww-port <PORT>       openWakeWord server port (default: 10400)
  --debug                 Verbose protocol-level logging to stderr
  --list-mics             Print available input devices and exit
  --help                  Show help
```

All settings can also be set via `config.json` (CLI flags override config).

## Port map

| Service | Port | Used by |
|---|---|---|
| STT server | 10300 | HA, satellite, Wyoming clients |
| TTS server | 10200 | HA, Wyoming clients |
| OWW server | 10400 | STT daemon, satellite |
| Satellite  | 10700 | HA (HA-orchestrated mode only) |

## Architecture

```
openWakeWord server (Python/ONNX, :10400)
  └─ Wyoming detection event
       └─ WakeWordClient (Swift/NWConnection)
            └─ onDetection → playSound → openSTTWindow

WyomingServer (NWListener TCP, :10300)    ← HA / satellite connects here
  └─ ClientSession
       ├─ wyomingDecode()
       ├─ SpeechEngineProtocol
       │    ├─ SpeechAnalyzerEngine  (macOS 26+)
       │    └─ SFSpeechEngine        (macOS 13–25)
       └─ wyomingEncode()

Local pipeline (--local-mic + --oww-host):
  Mic → MicCapture → WakeWordClient → STT window → LLMClient / HAClient → say → playSound

HA-orchestrated pipeline:
  HA → Satellite (:10700) → OWW (:10400) → STT (:10300) → HA agent → TTS (:10200) → Satellite

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
