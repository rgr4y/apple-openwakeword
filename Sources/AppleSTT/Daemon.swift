// Daemon: ties together WyomingServer, MicCapture, and AudioDeviceMonitor.
// Two modes:
//   server   — TCP Wyoming STT server (default). Home Assistant / satellite connects in.
//   passthru — additionally captures local mic and broadcasts transcripts on stdout.

import AVFoundation
import Foundation

final class Daemon {
    private let config: Config
    private var server: WyomingServer?
    private var micCapture: MicCapture?
    private var deviceMonitor: AudioDeviceMonitor?
    private var localEngine: SpeechEngineProtocol?
    private var restartPending = false

    init(config: Config) {
        self.config = config
    }

    // MARK: - Start

    func run() async {
        log("apple-stt-wyoming starting up — port=\(config.port) lang=\(config.language)")

        // Request mic access if we need local capture
        if config.localMic {
            let granted = await requestMicrophoneAccess()
            if !granted {
                log("ERROR: microphone access denied. Grant access in System Settings → Privacy → Microphone.")
                exit(1)
            }
            log("Microphone access granted")
        }

        // Start Wyoming TCP server
        let srv = WyomingServer(port: config.port, language: config.language)
        server = srv
        do {
            try srv.start()
        } catch {
            log("ERROR: failed to start Wyoming server: \(error)")
            exit(1)
        }

        // Start device monitor
        let monitor = AudioDeviceMonitor(queue: .main)
        deviceMonitor = monitor
        var lastDeviceID = AudioDeviceMonitor.currentDefaultInputDeviceID()
        if let id = lastDeviceID, let name = AudioDeviceMonitor.deviceName(id) {
            log("Default input device: \(name) (id=\(id))")
        }

        monitor.onChange = { [weak self] in
            let newID = AudioDeviceMonitor.currentDefaultInputDeviceID()
            if newID != lastDeviceID {
                lastDeviceID = newID
                let name = newID.flatMap { AudioDeviceMonitor.deviceName($0) } ?? "unknown"
                log("Input device changed → \(name)\(newID.map { " (id=\($0))" } ?? "")")
                self?.restartLocalCapture()
            }
        }
        monitor.start()

        // Optionally start local mic capture
        if config.localMic {
            startLocalCapture()
        }

        log("Ready — Wyoming STT server listening on :\(config.port)")
    }

    // MARK: - Local mic capture + passthru

    private func startLocalCapture() {
        guard config.localMic else { return }

        localEngine = makeSpeechEngine(language: config.language)
        localEngine?.onPartialTranscript = { text in
            // Optionally print partial to stdout with a prefix
            // print("[partial] \(text)")  // uncomment if desired
        }
        localEngine?.onFinalTranscript = { text in
            guard !text.isEmpty else { return }
            // JSON output on stdout for piping
            let obj: [String: Any] = ["type": "transcript", "text": text]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
        localEngine?.onError = { error in
            log("LocalEngine error: \(error)")
        }

        let engine = localEngine
        let capture = MicCapture { samples in
            engine?.feedSamples(samples)
        }
        micCapture = capture

        do {
            try capture.start()
            log("Local mic capture started")
        } catch {
            log("ERROR: failed to start mic capture: \(error)")
        }
    }

    private func restartLocalCapture() {
        guard config.localMic, !restartPending else { return }
        restartPending = true

        // Small delay to let CoreAudio settle after device switch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            self.localEngine?.stop()
            self.localEngine = nil

            do {
                try self.micCapture?.restart()
            } catch {
                log("ERROR restarting mic capture: \(error)")
                self.micCapture = nil
            }

            self.localEngine = makeSpeechEngine(language: self.config.language)
            self.localEngine?.onPartialTranscript = { _ in }
            self.localEngine?.onFinalTranscript = { text in
                guard !text.isEmpty else { return }
                let obj: [String: Any] = ["type": "transcript", "text": text]
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                    fflush(stdout)
                }
            }
            self.localEngine?.onError = { error in
                log("LocalEngine error after restart: \(error)")
            }

            // Reconnect capture → new engine
            if let cap = self.micCapture {
                let eng = self.localEngine
                // Reinstall tap pointing at new engine
                cap.stop()
                let newCap = MicCapture { samples in eng?.feedSamples(samples) }
                self.micCapture = newCap
                do {
                    try newCap.start()
                    log("Mic capture restarted on new device")
                } catch {
                    log("ERROR restarting mic capture: \(error)")
                }
            }
        }
    }
}
