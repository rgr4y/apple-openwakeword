// Wyoming wake word client.
// Connects to an openwakeword (or compatible) Wyoming server, streams 16kHz
// mono Int16 PCM audio from a MicCapture, and fires onDetection when the
// server sends a "detection" event.
//
// Usage:
//   let client = WakeWordClient(host: "10.0.1.50", port: 10400)
//   client.onDetection = { name in print("Wake word: \(name)") }
//   client.start()

import Foundation
import Network
import AppKit

final class WakeWordClient {
    var onDetection: ((String) -> Void)?

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var micCapture: MicCapture?
    private var readBuffer = Data()
    private var audioStartSent = false
    private let queue = DispatchQueue(label: "wakeword.client", qos: .userInitiated)
    private var reconnectTimer: DispatchSourceTimer?
    private var stopped = false
    private var activeSound: NSSound?
    private var retryCount = 0
    private static let retryDelays: [Double] = [1, 2, 5] // seconds
    // Debug counters
    private var chunksSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var statsTimer: DispatchSourceTimer?

    // Audio format sent to OWW (16kHz, 16-bit signed LE, mono)
    private let fmt = AudioFormat(rate: 16000, width: 2, channels: 1)

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    // MARK: - Public

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        cancelReconnect()
        statsTimer?.cancel()
        statsTimer = nil
        connection?.cancel()
        connection = nil
        micCapture?.stop()
        micCapture = nil
        audioStartSent = false
        log("WakeWordClient: stopped")
        playSound("CloseOrDisable2.wav", waitForCompletion: true)
    }


    // MARK: - Connection

    private func connect() {
        guard !stopped else { return }
        log("WakeWordClient: connecting to \(host):\(port)…")
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        conn.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .setup:
            log("WakeWordClient: setup", debug: true)
        case .preparing:
            log("WakeWordClient: preparing…", debug: true)
        case .ready:
            retryCount = 0
            log("WakeWordClient: connected to \(host):\(port)")
            audioStartSent = false
            readBuffer = Data()
            startMicAndStream()
            receive()
        case .waiting(let err):
            // Server not up yet — cancel and schedule retry with backoff
            let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
            retryCount += 1
            log("WakeWordClient: waiting (\(err)) — retrying in \(Int(delay))s")
            connection?.stateUpdateHandler = nil  // suppress .cancelled from triggering another retry
            connection?.cancel()
            connection = nil
            scheduleReconnect(after: delay)
        case .failed(let err):
            let delay = Self.retryDelays[min(retryCount, Self.retryDelays.count - 1)]
            retryCount += 1
            log("WakeWordClient: connection failed: \(err) — retrying in \(Int(delay))s")
            micCapture?.stop()
            micCapture = nil
            scheduleReconnect(after: delay)
        case .cancelled:
            break  // only happens from explicit cancel; reconnect handled by caller
        @unknown default:
            log("WakeWordClient: unknown state: \(state)", debug: true)
        }
    }

    private func scheduleReconnect(after delay: Double) {
        cancelReconnect()
        guard !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.reconnectTimer = nil
            self?.connect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Mic → OWW stream

    private func startMicAndStream() {
        chunksSent = 0
        bytesSent = 0

        // Send audio-start
        let startEvent = WyomingEvent(type: WyomingEventType.audioStart, data: fmt.eventData)
        sendRaw(wyomingEncode(startEvent))
        audioStartSent = true
        log("WakeWordClient: → audio-start sent (rate=\(fmt.rate), width=\(fmt.width), channels=\(fmt.channels))")

        // Periodic stats (every 5s when debug is on)
        statsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let kb = Double(self.bytesSent) / 1024.0
            log("WakeWordClient: streaming — \(self.chunksSent) chunks, \(String(format: "%.1f", kb)) KB sent", debug: true)
        }
        timer.resume()
        statsTimer = timer

        // Start mic capture; convert Float32 → Int16 and send as audio-chunk
        let capture = MicCapture(deviceID: nil, label: "oww-feed") { [weak self] samples in
            self?.sendSamples(samples)
        }
        micCapture = capture
        do {
            try capture.start()
            log("WakeWordClient: mic capture started (oww-feed)")
        } catch {
            log("WakeWordClient: mic start failed: \(error)")
        }
    }

    private func sendSamples(_ samples: [Float]) {
        guard audioStartSent, let conn = connection else { return }
        // Convert Float32 → Int16 PCM
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: i16.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var chunkData = fmt.eventData
        chunkData["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        let event = WyomingEvent(type: WyomingEventType.audioChunk, data: chunkData, payload: pcm)
        let encoded = wyomingEncode(event)
        conn.send(content: encoded, completion: .idempotent)
        chunksSent += 1
        bytesSent += UInt64(pcm.count)
        if chunksSent == 1 {
            log("WakeWordClient: → first audio-chunk sent (\(pcm.count) bytes, \(samples.count) samples)")
        }
    }

    // MARK: - Read loop (detection events)

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                self.consumeBuffer()
            }
            if let error {
                log("WakeWordClient: receive error: \(error)")
                return
            }
            if isComplete { return }
            self.receive()
        }
    }

    private func consumeBuffer() {
        while !readBuffer.isEmpty {
            guard let (event, consumed) = wyomingDecode(from: readBuffer) else { break }
            readBuffer.removeFirst(consumed)
            handleEvent(event)
        }
    }

    private func handleEvent(_ event: WyomingEvent) {
        switch event.type {
        case "detection":
            let name = event.data["name"] as? String ?? "unknown"
            let score = event.data["score"].flatMap { ($0 as? NSNumber)?.floatValue }
            let scoreStr = score.map { String(format: " (score=%.3f)", $0) } ?? ""
            log("WakeWordClient: *** WAKE WORD DETECTED: \(name)\(scoreStr) ***")
            DispatchQueue.main.async { [weak self] in
                self?.onDetection?(name)
            }
        case WyomingEventType.info:
            if let owwList = event.data["wake"] as? [[String: Any]] {
                let names = owwList.compactMap { $0["name"] as? String }
                log("WakeWordClient: OWW models available: \(names.joined(separator: ", "))")
            }
        default:
            log("WakeWordClient: received \(event.type)", debug: true)
        }
    }

    // MARK: - Helpers

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }
}

// MARK: - Module-level sound helper (callable from Daemon and WakeWordClient)

/// Play a WAV/AIFF from the sounds/ directory next to the project root.
/// - Parameter waitForCompletion: block the calling thread until audio finishes (use at shutdown).
func playSound(_ filename: String, waitForCompletion: Bool = false) {
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let projectRoot = execURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let soundURL = projectRoot.appendingPathComponent("sounds/\(filename)")
    log("playSound: \(soundURL.path)")
    guard let sound = NSSound(contentsOf: soundURL, byReference: false) else {
        log("playSound: file not found at \(soundURL.path)")
        return
    }
    let duration = sound.duration
    // NSSound must be used on the main thread
    DispatchQueue.main.async {
        let ok = sound.play()
        log("playSound: play() → \(ok) for \(filename) (duration=\(String(format: "%.2f", duration))s)")
        // Retain sound until playback ends (NSSound is non-retaining by default)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.5) { _ = sound.self }
    }
    if waitForCompletion {
        Thread.sleep(forTimeInterval: duration + 0.2)
    }
}
