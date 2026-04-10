// Wyoming STT TCP server.
// Each connected client gets a dedicated ClientSession.
// Session state machine: idle → streaming → transcribing → idle
//
// Protocol flow:
//   Client → Server:  audio-start, audio-chunk*, audio-stop
//   Server → Client:  transcript-chunk* (optional), transcript
//   Either side:      describe → info, ping → pong

import Foundation
import Network

final class WyomingServer {
    let port: NWEndpoint.Port
    let language: String
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ClientSession] = [:]
    private let queue = DispatchQueue(label: "wyoming.server", qos: .userInitiated)

    init(port: UInt16, language: String) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.language = language
    }

    func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: port)
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log("WyomingServer: listening on port \(self?.port.rawValue ?? 0)")
            case .failed(let err):
                log("WyomingServer: listener failed: \(err)")
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            sessions.values.forEach { $0.cancel() }
            sessions.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = ClientSession(
            connection: connection,
            language: language,
            onDone: { [weak self] session in
                self?.queue.async {
                    self?.sessions.removeValue(forKey: ObjectIdentifier(session))
                }
            }
        )
        queue.async {
            self.sessions[ObjectIdentifier(session)] = session
        }
        session.start()
        log("WyomingServer: accepted connection from \(connection.endpoint)")
    }
}

// MARK: - Client session

private final class ClientSession {
    typealias DoneHandler = (ClientSession) -> Void

    private let connection: NWConnection
    private let language: String
    private let onDone: DoneHandler
    private let queue: DispatchQueue
    private var readBuffer = Data()
    private var engine: SpeechEngineProtocol?
    private var audioFormat: AudioFormat = .wyomingDefault
    private var isStreaming = false
    private var chunkCount = 0
    private var chunkBytes = 0

    init(connection: NWConnection, language: String, onDone: @escaping DoneHandler) {
        self.connection = connection
        self.language = language
        self.onDone = onDone
        self.queue = DispatchQueue(
            label: "wyoming.session.\(connection.endpoint)",
            qos: .userInitiated
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed(let err):
                log("Session: connection failed: \(err)")
                self?.done()
            case .cancelled:
                self?.done()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: - Read loop

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(data)
                self.consumeBuffer()
            }
            if let error {
                log("Session: receive error: \(error)")
                self.done()
                return
            }
            if isComplete {
                self.done()
                return
            }
            self.receive()
        }
    }

    private func consumeBuffer() {
        while !readBuffer.isEmpty {
            guard let (event, consumed) = wyomingDecode(from: readBuffer) else { break }
            readBuffer.removeFirst(consumed)
            handle(event)
        }
    }

    // MARK: - Event handling

    private func handle(_ event: WyomingEvent) {
        switch event.type {
        case WyomingEventType.describe:
            log("Session: ← describe (HA is probing for STT info)", debug: true)
            send(.info(
                name: "apple-stt",
                description: "Apple on-device Speech Recognition",
                languages: installedLanguages(),
                version: "1.0"
            ))
            log("Session: → info sent (\(installedLanguages().count) languages)", debug: true)

        case WyomingEventType.ping:
            send(.pong())

        case WyomingEventType.audioStart:
            startStreaming(formatData: event.data)

        case WyomingEventType.audioChunk:
            handleAudioChunk(event)

        case WyomingEventType.audioStop:
            stopStreaming()

        default:
            break
        }
    }

    // MARK: - Streaming control

    private func startStreaming(formatData: [String: Any]) {
        audioFormat = AudioFormat(eventData: formatData) ?? .wyomingDefault
        isStreaming = true
        chunkCount = 0
        chunkBytes = 0
        log("Session: ← audio-start rate=\(audioFormat.rate) width=\(audioFormat.width) ch=\(audioFormat.channels) — streaming begun", debug: true)

        // Create engine fresh for each utterance
        let eng = makeSpeechEngine(language: language)
        engine = eng

        eng.onPartialTranscript = { [weak self] text in
            guard let self else { return }
            log("Session: partial → \"\(text)\"", debug: true)
            self.send(.transcriptChunk(text: text))
        }
        eng.onFinalTranscript = { [weak self] text in
            guard let self else { return }
            log("Session: → transcript = \"\(text)\"")
            self.send(.transcript(text: text, language: self.language))
            self.isStreaming = false
            self.engine = nil
        }
        eng.onError = { [weak self] error in
            guard let self else { return }
            log("Session: engine error: \(error)")
            self.send(.error(text: error.localizedDescription))
            self.isStreaming = false
            self.engine = nil
        }
    }

    private func handleAudioChunk(_ event: WyomingEvent) {
        guard isStreaming, let engine else { return }
        guard let payload = event.payload, !payload.isEmpty else { return }

        chunkCount += 1
        chunkBytes += payload.count

        // Resolve format from chunk data (may differ from audio-start)
        let fmt = AudioFormat(eventData: event.data) ?? audioFormat

        // Convert PCM bytes to Float32 16kHz mono
        let samples = convertToFloat32(payload, format: fmt)
        engine.feedSamples(samples)
    }

    private func stopStreaming() {
        guard isStreaming else { return }
        let kb = String(format: "%.1f", Double(chunkBytes) / 1024.0)
        log("Session: ← audio-stop — \(chunkCount) chunks, \(kb) KB received — transcribing...", debug: true)
        engine?.finishUtterance()
        // Final transcript is delivered via onFinalTranscript callback
    }

    // MARK: - Send

    private func send(_ event: WyomingEvent) {
        let data = wyomingEncode(event)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                log("Session: send error: \(error)")
            }
        })
    }

    // MARK: - Done

    private func done() {
        engine?.stop()
        engine = nil
        onDone(self)
    }
}

// MARK: - PCM conversion

/// Converts raw PCM bytes from a Wyoming audio-chunk into 16 kHz mono Float32.
private func convertToFloat32(_ payload: Data, format: AudioFormat) -> [Float] {
    let sampleCount = payload.count / format.width
    guard sampleCount > 0 else { return [] }

    // Step 1: decode to Float32 at source rate/channels
    var floats: [Float]
    switch format.width {
    case 2: // Int16 PCM (most common)
        floats = payload.withUnsafeBytes { ptr in
            let shorts = ptr.bindMemory(to: Int16.self)
            return shorts.map { Float($0) / 32768.0 }
        }
    case 4: // Float32 already
        floats = payload.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    case 1: // Unsigned 8-bit PCM
        floats = payload.map { Float(Int($0) - 128) / 128.0 }
    default:
        return []
    }

    // Step 2: mix to mono if multi-channel
    let ch = max(1, format.channels)
    if ch > 1 {
        let frames = floats.count / ch
        floats = (0..<frames).map { i in
            (0..<ch).reduce(Float(0)) { $0 + floats[i * ch + $1] } / Float(ch)
        }
    }

    // Step 3: resample to 16 kHz
    let srcRate = Double(format.rate)
    let dstRate = 16_000.0
    guard abs(srcRate - dstRate) > 1.0 else { return floats }

    let ratio = srcRate / dstRate
    let outCount = max(1, Int(Double(floats.count) / ratio))
    var out = [Float]()
    out.reserveCapacity(outCount)
    var idx: Double = 0
    while Int(idx) < floats.count {
        out.append(floats[Int(idx)])
        idx += ratio
    }
    return out
}

// MARK: - Installed languages helper

#if canImport(Speech)
import Speech
#endif

private func installedLanguages() -> [String] {
    if #available(macOS 26, *) {
        // SpeechTranscriber.installedLocales is async; return sync approximation
        return SFSpeechRecognizer.supportedLocales().map { $0.identifier }
    }
    return SFSpeechRecognizer.supportedLocales().map { $0.identifier }
}
