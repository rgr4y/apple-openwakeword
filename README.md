# apple-stt-wyoming

Apple on-device Speech Recognition exposed as a [Wyoming protocol](https://github.com/OHF-Voice/wyoming) STT server.

Plug it into Home Assistant's Wyoming integration (alongside openwakeword) and get
zero-latency, fully offline transcription using Apple's built-in speech models — no
API keys, no cloud calls.

## Features

- **Wyoming-compatible STT server** — Home Assistant, satellites, and any Wyoming
  client can connect and get transcripts
- **Streaming partials** — sends `transcript-chunk` events during recognition, then
  a final `transcript` when the utterance ends
- **Two backends**, selected automatically at runtime:
  - macOS 26+ → `SpeechAnalyzer` + `SpeechTranscriber` (streaming, ultra-low latency)
  - macOS 13–25 → `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
- **Default input device tracking** — detects system audio device changes via CoreAudio
  and re-inits instantly (plug/unplug a USB mic, switch in System Settings, etc.)
- **Optional local mic mode** — `--local-mic` captures from the default mic and prints
  JSON transcript lines to stdout for easy piping

## Requirements

- macOS 13.0 or later (macOS 26 recommended for best quality)
- Swift 5.9 / Xcode 15 or later
- For `--local-mic`: microphone permission (granted via System Settings → Privacy & Security → Microphone)

## Build

```bash
cd apple-stt-wyoming
swift build -c release
```

Binary lands at `.build/release/AppleSTT`.

Install system-wide:

```bash
sudo cp .build/release/AppleSTT /usr/local/bin/apple-stt-wyoming
```

## Usage

```
apple-stt-wyoming [OPTIONS]

OPTIONS:
  --port, -p <PORT>     TCP port (default: 10300)
  --language, -l <LANG> Language code, e.g. en, en-US, fr (default: en)
  --local-mic           Also capture local mic; print JSON transcripts to stdout
  --debug               Verbose logging to stderr
  --version             Print version
  --help                Show help
```

### Start the server (Wyoming STT mode)

```bash
apple-stt-wyoming --port 10300 --language en
```

Home Assistant connects to `<your-mac>:10300` as a Wyoming STT provider.

### Local mic transcription (pipe to anywhere)

```bash
apple-stt-wyoming --local-mic | jq .
```

Each final transcript is emitted as a JSON line on stdout:

```json
{"text":"hello world","type":"transcript"}
```

## Home Assistant Setup

1. Build and run the daemon on your Mac.
2. In Home Assistant: **Settings → Devices & Services → Add Integration → Wyoming Protocol**
3. Host: your Mac's IP, Port: `10300`
4. The integration auto-discovers it as an STT provider.
5. Pair with an openwakeword satellite (running separately on a Pi, etc.) for a full
   always-on voice assistant pipeline.

## Wyoming Protocol Summary

This daemon implements the STT subset of the Wyoming protocol:

| Direction     | Event            | Description                           |
|---------------|------------------|---------------------------------------|
| client → server | `describe`     | Request service info                  |
| server → client | `info`         | Service capabilities and languages    |
| client → server | `audio-start`  | Begin audio stream (`rate/width/ch`)  |
| client → server | `audio-chunk`  | PCM audio payload                     |
| client → server | `audio-stop`   | End of utterance                      |
| server → client | `transcript-chunk` | Streaming partial result          |
| server → client | `transcript`   | Final transcription result            |
| client → server | `ping`         | Keepalive                             |
| server → client | `pong`         | Keepalive reply                       |

Audio format: any PCM (int16, float32, uint8), any sample rate, any channels — the
daemon converts to 16 kHz mono Float32 before feeding the speech engine.

## Architecture

```
WyomingServer (NWListener TCP)
  └─ ClientSession (per connection)
       ├─ wyomingDecode()   — parse incoming events
       ├─ SpeechEngineProtocol
       │    ├─ SpeechAnalyzerEngine  (macOS 26+)
       │    └─ SFSpeechEngine        (macOS 13-25)
       └─ wyomingEncode()   — write outgoing events

AudioDeviceMonitor (CoreAudio HAL property listener)
  └─ fires onChange → Daemon restarts MicCapture + SpeechEngine

MicCapture (AVAudioEngine)
  └─ taps default input node → resamples to 16kHz mono Float32
```

## License

MIT
