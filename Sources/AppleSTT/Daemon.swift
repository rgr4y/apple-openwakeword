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
    private var mic2Capture: MicCapture?
    private var deviceMonitor: AudioDeviceMonitor?
    private var localEngine: SpeechEngineProtocol?
    private var localEngine2: SpeechEngineProtocol?
    // Resolved device IDs (nil = system default for mic1, absent for mic2 if not configured)
    private var mic1DeviceID: AudioDeviceID? = nil
    private var mic1Label: String = "default"
    private var mic2DeviceID: AudioDeviceID? = nil
    private var mic2Label: String = "mic2"
    private var restartPending = false
    private var wakeWordClient: WakeWordClient?
    private var llmClient: LLMClient?
    private var haClient: HAClient?
    // Triggered STT state (used when --oww-host is set with --local-mic)
    private var sttActive = false
    private var sttWindowTimer: DispatchSourceTimer?
    private var silenceTimer: DispatchSourceTimer?
    private var lastPartialAt: Date = .distantPast
    // True when two mic captures are running; drives "source" field in JSON output.
    private var dualMic: Bool { mic2DeviceID != nil }

    init(config: Config) {
        self.config = config
    }

    // MARK: - Shutdown

    func stopWakeWordClient() {
        wakeWordClient?.stop()
        wakeWordClient = nil
    }

    // MARK: - Start

    func run() async {
        log("apple-stt-wyoming starting up — port=\(config.port) lang=\(config.language)")

        // Request mic access if we need local capture or OWW streaming
        if config.localMic || config.owwHost != nil {
            await ensureMicrophoneAccess()
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

        // Resolve named device arguments to CoreAudio IDs before starting capture.
        if let name = config.mic1DeviceName {
            if let (id, resolved) = AudioDeviceMonitor.findDevice(named: name) {
                mic1DeviceID = id
                mic1Label = resolved
                log("Mic1 → \(resolved) (id=\(id))")
            } else {
                log("WARNING: no input device found matching \"\(name)\", mic1 uses system default")
            }
        }
        if let name = config.mic2DeviceName {
            if let (id, resolved) = AudioDeviceMonitor.findDevice(named: name) {
                mic2DeviceID = id
                mic2Label = resolved
                log("Mic2 → \(resolved) (id=\(id))")
            } else {
                log("WARNING: no input device found matching \"\(name)\", mic2 disabled")
            }
        }

        // Optionally start local mic capture
        if config.localMic {
            startLocalCapture()
            if dualMic { startMic2Capture() }
        }

        // Start wake word client if OWW host is configured
        if let owwHost = config.owwHost {
            let client = WakeWordClient(host: owwHost, port: config.owwPort)
            client.onDetection = { [weak self] name in
                guard let self else { return }
                // Ignore re-triggers while an STT window is already open
                if self.sttActive {
                    log("WakeWordClient: wake word ignored — STT window already active")
                    return
                }
                playSound("OpenOrEnable2.wav")
                // JSON line on stdout
                let obj: [String: Any] = ["type": "wake", "name": name]
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                    fflush(stdout)
                }
                // If local-mic is also running, open a timed STT window
                if self.config.localMic {
                    self.openSTTWindow()
                }
            }
            wakeWordClient = client
            client.start()
            log("WakeWordClient: streaming mic → OWW at \(owwHost):\(config.owwPort)")
        }

        // Set up LLM client if endpoint is configured and enabled
        if config.llmEnabled, let llmEndpoint = config.llmEndpoint {
            let client = LLMClient(
                endpoint: llmEndpoint,
                model: config.llmModel,
                systemPrompt: config.llmSystemPrompt
            )
            // Register HA as a tool if configured
            if let haHost = config.haHost, let haToken = config.haToken {
                let ha = HAClient(host: haHost, token: haToken, language: config.language, agentId: config.haAgentId)
                client.registerTool(ha, name: "home_assistant")
                log("LLM: registered home_assistant tool → \(haHost)")
            }
            llmClient = client
            log("LLM client → \(llmEndpoint) model=\(config.llmModel)")
            Task { await client.healthCheck() }
        } else if let haHost = config.haHost, let haToken = config.haToken {
            // No LLM — send transcripts directly to HA
            haClient = HAClient(host: haHost, token: haToken, language: config.language, agentId: config.haAgentId)
            log("HA direct mode → \(haHost)\(config.haAgentId.map { " agent=\($0)" } ?? " (no agent_id — HA will use built-in agent)")")
        }

        log("Ready — Wyoming STT server listening on :\(config.port)")
    }

    // MARK: - Local mic capture + passthru

    private func startLocalCapture() {
        guard config.localMic else { return }

        localEngine = makeSpeechEngine(language: config.language)
        localEngine?.onPartialTranscript = { text in
            // Show live partials on stderr for debugging
            log("[partial] \(text)", debug: false)
        }
        let source: String? = dualMic ? mic1Label : nil
        localEngine?.onFinalTranscript = { text in
            guard !text.isEmpty else { return }
            var obj: [String: Any] = ["type": "transcript", "text": text]
            if let src = source { obj["source"] = src }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
        localEngine?.onError = { error in
            log("LocalEngine error: \(error)")
        }

        let triggered = config.owwHost != nil
        let capture = MicCapture(deviceID: mic1DeviceID, label: mic1Label) { [weak self] samples in
            guard let self else { return }
            // In triggered mode, only feed the engine during an active STT window
            guard !triggered || self.sttActive else { return }
            // Always use self.localEngine so window resets pick up the fresh engine
            self.localEngine?.feedSamples(samples)
        }
        micCapture = capture

        do {
            try capture.start()
            log("Local mic capture started (\(mic1Label))")
        } catch {
            log("ERROR: failed to start mic capture: \(error)")
        }
    }

    // MARK: - Triggered STT window (used when --oww-host is active)

    private func openSTTWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Reset engine so we get a clean slate (drops any residual audio)
            self.localEngine?.stop()
            self.localEngine = self.makeFreshLocalEngine()
            self.sttActive = true
            self.lastPartialAt = .distantPast
            log("STT window OPEN — listening for \(Int(self.config.sttWindowSeconds))s")

            // Hard max-duration timer
            self.sttWindowTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + self.config.sttWindowSeconds)
            timer.setEventHandler { [weak self] in self?.closeSTTWindow() }
            timer.resume()
            self.sttWindowTimer = timer

            // Silence watchdog is armed on first partial, not at window open.
            // This avoids firing during the natural pause between wake word and speech.
            self.silenceTimer?.cancel()
            self.silenceTimer = nil
        }
    }

    private func armSilenceTimer() {
        guard let silence = config.silenceWindowSeconds, sttActive else { return }
        // Cancel and reschedule — gives a clean `silence`s from the last partial
        silenceTimer?.cancel()
        let st = DispatchSource.makeTimerSource(queue: .main)
        st.schedule(deadline: .now() + silence)
        st.setEventHandler { [weak self] in
            log("STT window CLOSING — silence timeout")
            self?.closeSTTWindow()
        }
        st.resume()
        silenceTimer = st
    }

    private func closeSTTWindow() {
        sttWindowTimer?.cancel()
        sttWindowTimer = nil
        silenceTimer?.cancel()
        silenceTimer = nil
        guard sttActive else { return }
        sttActive = false
        log("STT window CLOSED — finalizing")
        localEngine?.finishUtterance()
    }

    private func makeFreshLocalEngine() -> SpeechEngineProtocol {
        let eng = makeSpeechEngine(language: config.language)
        eng.onPartialTranscript = { [weak self] text in
            self?.lastPartialAt = Date()
            log("[partial] \(text)")
            // Arm (or reset) the trailing-edge silence timer on every partial
            self?.armSilenceTimer()
        }
        let source: String? = dualMic ? mic1Label : nil
        let minWords = config.minTranscriptWords
        eng.onFinalTranscript = { [weak self] text in
            guard !text.isEmpty else { return }
            let wordCount = text.split(separator: " ").count
            guard wordCount >= minWords else {
                log("transcript ignored — too short (\(wordCount) word(s)): \"\(text)\"")
                return
            }
            var obj: [String: Any] = ["type": "transcript", "text": text]
            if let src = source { obj["source"] = src }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
            // Auto-close window if engine already delivered a final
            self?.closeSTTWindow()

            // Send to LLM if configured, otherwise direct to HA if available
            if let llm = self?.llmClient {
                Task {
                    if let response = await llm.process(text) {
                        log("LLM response: \(response)")
                        let robj: [String: Any] = ["type": "llm_response", "text": response, "input": text]
                        if let data = try? JSONSerialization.data(withJSONObject: robj, options: [.sortedKeys]),
                           let line = String(data: data, encoding: .utf8) {
                            print(line)
                            fflush(stdout)
                        }
                        self?.speak(response) { playSound("CloseOrDisable2.wav") }
                    }
                }
            } else if let ha = self?.haClient {
                Task {
                    log("HA direct: \"\(text)\"")
                    let response = await ha.execute(arguments: ["command": text])
                    log("HA response: \(response)")
                    let robj: [String: Any] = ["type": "ha_response", "text": response, "input": text]
                    if let data = try? JSONSerialization.data(withJSONObject: robj, options: [.sortedKeys]),
                       let line = String(data: data, encoding: .utf8) {
                        print(line)
                        fflush(stdout)
                    }
                    self?.speak(response) { playSound("CloseOrDisable2.wav") }
                }
            }
        }
        eng.onError = { error in log("LocalEngine error: \(error)") }
        return eng
    }

    // MARK: - Second mic capture

    private func startMic2Capture() {
        guard let devID = mic2DeviceID else { return }

        let eng2 = makeSpeechEngine(language: config.language)
        localEngine2 = eng2
        eng2.onPartialTranscript = { text in log("[partial/mic2] \(text)") }
        let label = mic2Label
        eng2.onFinalTranscript = { text in
            guard !text.isEmpty else { return }
            let obj: [String: Any] = ["type": "transcript", "text": text, "source": label]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
        eng2.onError = { error in
            log("LocalEngine2 error: \(error)")
        }

        let capture = MicCapture(deviceID: devID, label: label) { samples in
            eng2.feedSamples(samples)
        }
        mic2Capture = capture

        do {
            try capture.start()
            log("Mic2 capture started (\(label))")
        } catch {
            log("ERROR: failed to start mic2 capture: \(error)")
        }
    }

    private func restartLocalCapture() {
        // Only react to default-device changes when mic1 is tracking the system default.
        // A pinned mic1 (--mic1 <name>) isn't affected by the default changing.
        guard config.localMic, config.mic1DeviceName == nil, !restartPending else { return }
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
            let source: String? = self.dualMic ? self.mic1Label : nil
            self.localEngine?.onFinalTranscript = { text in
                guard !text.isEmpty else { return }
                var obj: [String: Any] = ["type": "transcript", "text": text]
                if let src = source { obj["source"] = src }
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
                cap.stop()
                // mic1DeviceID is nil here because we only restart when tracking system default
                let newCap = MicCapture(deviceID: nil, label: self.mic1Label) { samples in
                    eng?.feedSamples(samples)
                }
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

    // MARK: - TTS output

    /// Speak text using macOS built-in `say` command (non-blocking).
    private func speak(_ text: String, completion: (() -> Void)? = nil) {
        let rate = config.sayRate
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-r", String(rate), text]
            do {
                try process.run()
                process.waitUntilExit()
                completion?()
            } catch {
                log("TTS (say) failed: \(error)")
                completion?()
            }
        }
    }
}
