// Command-line configuration parsed from argv + optional config.json file.

import Foundation

// MARK: - File-based config (config.json)

struct ConfigFile: Decodable {
    // Root-level
    var language: String?
    /// TCP host/address to bind all servers (default: 0.0.0.0)
    var host: String?
    /// Enable verbose debug logging across all components
    var debug: Bool?

    struct STT: Decodable {
        var port: UInt16?
        /// Seconds to keep the STT window open after a wake word (default: 8)
        var windowSeconds: Double?
        /// Seconds of silence (no new partial) before auto-closing window (nil = disabled)
        var silenceWindowSeconds: Double?
        /// Minimum word count for a transcript to be emitted (default: 1)
        var minTranscriptWords: Int?
        var mic1: String?
        var mic2: String?
        /// Set to false to disable Wyoming TCP listener (local-only / HA-direct mode)
        var wyomingEnabled: Bool?
    }

    struct TTS: Decodable {
        var port: UInt16?
        var voice: String?
        /// Speech rate in WPM (default: 220)
        var rate: Int?
        var rulesFile: String?
    }

    struct OWW: Decodable {
        var host: String?
        var port: UInt16?
        /// Wake word model name (e.g. "alexa", "hey_mycroft")
        var model: String?
        /// Detection confidence threshold 0.0–1.0 (default: 0.5)
        var threshold: Double?
    }

    struct LLM: Decodable {
        /// Base URL for the OpenAI-compatible endpoint (e.g. http://127.0.0.1:11434)
        var endpoint: String?
        /// Model name to send in the request body
        var model: String?
        /// Optional system prompt override
        var systemPrompt: String?
        /// Set to false to bypass the LLM and send all transcripts directly to HA (default: true)
        var enabled: Bool?
    }

    struct HA: Decodable {
        /// Home Assistant base URL (e.g. http://homeassistant.local:8123)
        var host: String?
        /// Long-lived access token
        var token: String?
        /// Conversation agent entity ID (e.g. conversation.google_generative_ai_conversation)
        /// If omitted, HA uses its built-in rule-based agent — NOT the one configured in the UI.
        var agentId: String?
    }

    var stt: STT?
    var tts: TTS?
    var oww: OWW?
    var llm: LLM?
    var ha: HA?

    static func load(path: String = "./config.json") -> ConfigFile {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return ConfigFile() }
        do {
            return try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            fputs("WARNING: failed to parse \(path): \(error)\n", stderr)
            return ConfigFile()
        }
    }
}

// MARK: - Runtime config

struct Config {
    var host: String = "0.0.0.0"    // Bind address for Wyoming server
    var port: UInt16 = 10_300       // STT Wyoming port
    var language: String = "en"
    var localMic: Bool = false
    var mic1DeviceName: String? = nil
    var mic2DeviceName: String? = nil
    var listMics: Bool = false
    var owwHost: String? = nil
    var owwPort: UInt16 = 10_400
    var debug: Bool = false
    /// When false, the Wyoming TCP server is not started (local-only / HA-direct mode)
    var wyomingEnabled: Bool = true

    // LLM (OpenAI-compatible endpoint)
    var llmEndpoint: String? = nil
    var llmModel: String = "apple-foundationmodel"
    var llmSystemPrompt: String? = nil
    var llmEnabled: Bool = true

    // Home Assistant
    var haHost: String? = nil
    var haToken: String? = nil
    var haAgentId: String? = nil

    // STT window tuning
    var sttWindowSeconds: Double = 8.0
    var silenceWindowSeconds: Double? = nil
    var minTranscriptWords: Int = 1
    /// Words-per-minute rate for /usr/bin/say (default: 242 = 220 * 1.1)
    var sayRate: Int = 242

    static func parse() -> Config {
        var cfg = Config()

        // 1. Load file-based config first (lowest priority)
        let file = ConfigFile.load()
        cfg.applyFile(file)

        // 2. CLI args override file values
        var i = 1
        let args = CommandLine.arguments
        while i < args.count {
            switch args[i] {
            case "--port", "-p":
                i += 1
                if i < args.count, let v = UInt16(args[i]) { cfg.port = v }
            case "--language", "--lang", "-l":
                i += 1
                if i < args.count { cfg.language = args[i] }
            case "--local-mic":
                cfg.localMic = true
            case "--mic1":
                i += 1
                if i < args.count { cfg.mic1DeviceName = args[i] }
            case "--mic2":
                i += 1
                if i < args.count { cfg.mic2DeviceName = args[i] }
            case "--list-mics":
                cfg.listMics = true
            case "--oww-host":
                i += 1
                if i < args.count { cfg.owwHost = args[i] }
            case "--oww-port":
                i += 1
                if i < args.count, let v = UInt16(args[i]) { cfg.owwPort = v }
            case "--stt-window":
                i += 1
                if i < args.count, let v = Double(args[i]) { cfg.sttWindowSeconds = v }
            case "--silence-window":
                i += 1
                if i < args.count, let v = Double(args[i]) { cfg.silenceWindowSeconds = v }
            case "--min-words":
                i += 1
                if i < args.count, let v = Int(args[i]) { cfg.minTranscriptWords = v }
            case "--ha-mode":
                // HA-orchestrated mode: disable local mic and OWW client.
                // HA drives the full pipeline; this daemon is a pure STT server.
                cfg.localMic = false
                cfg.owwHost = nil
            case "--debug":
                cfg.debug = true
            case "--help", "-h":
                printHelp()
                exit(0)
            case "--version":
                print("apple-stt-wyoming 1.0.0")
                exit(0)
            default:
                break
            }
            i += 1
        }
        return cfg
    }

    mutating func applyFile(_ f: ConfigFile) {
        if let v = f.language   { language = v }
        if let v = f.host       { host = v }
        if let v = f.debug      { debug = v }
        if let s = f.stt {
            if let v = s.port                { port = v }
            if let v = s.windowSeconds       { sttWindowSeconds = v }
            if let v = s.silenceWindowSeconds { silenceWindowSeconds = v }
            if let v = s.minTranscriptWords  { minTranscriptWords = v }
            if let v = s.mic1               { mic1DeviceName = v }
            if let v = s.mic2               { mic2DeviceName = v }
            if let v = s.wyomingEnabled      { wyomingEnabled = v }
        }
        if let t = f.tts {
            if let v = t.rate { sayRate = Int(Double(v) * 1.1) }
        }
        if let o = f.oww {
            if let v = o.host   { owwHost = v }
            if let v = o.port   { owwPort = v }
        }
        if let l = f.llm {
            if let v = l.endpoint     { llmEndpoint = v }
            if let v = l.model        { llmModel = v }
            if let v = l.systemPrompt { llmSystemPrompt = v }
            if let v = l.enabled      { llmEnabled = v }
        }
        if let h = f.ha {
            if let v = h.host              { haHost = v }
            if let v = h.token, !v.isEmpty { haToken = v }
            if let v = h.agentId           { haAgentId = v }
        }
    }
}

private func printHelp() {
    print("""
    apple-stt-wyoming — Apple on-device STT as a Wyoming protocol server

    USAGE:
      apple-stt-wyoming [OPTIONS]

    OPTIONS:
      --port, -p <PORT>        TCP port to listen on (default: 10300)
      --language, -l <LANG>    Speech recognition language, e.g. en, en-US, fr (default: en)
      --local-mic              Also capture local microphone and print JSON transcripts to stdout
      --mic1 <NAME>            Pin the primary mic to a device whose name contains NAME
                               (default: system default input device)
      --mic2 <NAME>            Enable a second microphone; NAME is matched case-insensitively
                               against available input device names. Requires --local-mic.
      --list-mics              Print available input devices and exit
      --oww-host <HOST>        Stream mic audio to an openwakeword Wyoming server at HOST
                               and log detections. Combine with --local-mic to also transcribe.
      --oww-port <PORT>        OWW server port (default: 10400)
      --debug                  Enable verbose logging
      --version                Print version and exit
      --help, -h               Show this help

    EXAMPLES:
      # Start Wyoming STT server on default port
      apple-stt-wyoming

      # Custom port and language
      apple-stt-wyoming --port 10301 --language fr

      # Local mic transcription piped to jq
      apple-stt-wyoming --local-mic | jq .

      # Two mics (Kitchen USB mic + built-in)
      apple-stt-wyoming --local-mic --mic1 "USB Audio" --mic2 "MacBook"

      # List available input devices
      apple-stt-wyoming --list-mics

    WYOMING PROTOCOL:
      Clients (e.g. Home Assistant) connect via TCP and send:
        audio-start → audio-chunk* → audio-stop
      The daemon responds with:
        transcript-chunk* (streaming partials), then transcript (final)

    REQUIREMENTS:
      macOS 26+  : Uses Apple SpeechAnalyzer (best quality, streaming)
      macOS 13+  : Falls back to SFSpeechRecognizer with on-device mode
      Microphone : Required for --local-mic mode
                   Grant via: System Settings → Privacy & Security → Microphone
    """)
}
