// Command-line configuration parsed from argv.

import Foundation

struct Config {
    var port: UInt16 = 10_300   // Default Wyoming STT port
    var language: String = "en"
    var localMic: Bool = false   // Also capture local mic and print JSON transcripts
    var debug: Bool = false

    static func parse() -> Config {
        var cfg = Config()
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
