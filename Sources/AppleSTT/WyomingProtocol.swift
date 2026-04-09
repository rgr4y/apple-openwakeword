// Wyoming protocol wire format implementation.
// Spec: https://github.com/OHF-Voice/wyoming
//
// Wire format per message:
//   Header JSON line  (ends with \n)
//   [data_length bytes of JSON]   — merged into event.data
//   [payload_length bytes of raw] — event.payload
//
// Header fields:
//   "type"           required  event type string
//   "version"        optional  protocol version
//   "data_length"    optional  byte count of inline data block
//   "payload_length" optional  byte count of binary payload

import Foundation

// MARK: - Event

struct WyomingEvent {
    let type: String
    var data: [String: Any]
    var payload: Data?
}

// MARK: - Known event types

enum WyomingEventType {
    // Audio stream
    static let audioStart   = "audio-start"
    static let audioChunk   = "audio-chunk"
    static let audioStop    = "audio-stop"
    // ASR
    static let transcript        = "transcript"
    static let transcriptChunk   = "transcript-chunk"
    static let transcriptStart   = "transcript-start"
    static let transcriptStop    = "transcript-stop"
    // Service info
    static let describe = "describe"
    static let info     = "info"
    // Errors
    static let error    = "error"
    static let ping     = "ping"
    static let pong     = "pong"
}

// MARK: - Encode

func wyomingEncode(_ event: WyomingEvent) -> Data {
    var header: [String: Any] = ["type": event.type, "version": "1.0"]

    var dataBytes: Data? = nil
    if !event.data.isEmpty {
        dataBytes = try? JSONSerialization.data(withJSONObject: event.data,
                                                options: [.sortedKeys])
        if let d = dataBytes {
            header["data_length"] = d.count
        }
    }

    if let payload = event.payload {
        header["payload_length"] = payload.count
    }

    guard let headerData = try? JSONSerialization.data(withJSONObject: header,
                                                       options: [.sortedKeys]) else {
        return Data()
    }

    var result = Data()
    result.append(headerData)
    result.append(UInt8(ascii: "\n"))
    if let d = dataBytes  { result.append(d) }
    if let p = event.payload { result.append(p) }
    return result
}

// MARK: - Decode (streaming buffer)

/// Returns (event, bytesConsumed) when a full event is parsed, nil if more data needed.
func wyomingDecode(from buffer: Data) -> (WyomingEvent, Int)? {
    // Need at least a newline-terminated header line
    guard let newlineIdx = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }

    let headerData = buffer[buffer.startIndex..<newlineIdx]
    guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
          let type = header["type"] as? String else { return nil }

    var offset = buffer.index(after: newlineIdx)

    // Merge inline data block if present
    var data: [String: Any] = (header["data"] as? [String: Any]) ?? [:]
    if let dataLength = (header["data_length"] as? Int ?? (header["data_length"] as? NSNumber)?.intValue),
       dataLength > 0 {
        guard buffer.endIndex >= buffer.index(offset, offsetBy: dataLength) else { return nil }
        let dataSlice = buffer[offset..<buffer.index(offset, offsetBy: dataLength)]
        if let parsed = (try? JSONSerialization.jsonObject(with: dataSlice)) as? [String: Any] {
            data.merge(parsed) { _, new in new }
        }
        offset = buffer.index(offset, offsetBy: dataLength)
    }

    var payload: Data? = nil
    if let payloadLength = (header["payload_length"] as? Int ?? (header["payload_length"] as? NSNumber)?.intValue),
       payloadLength > 0 {
        guard buffer.endIndex >= buffer.index(offset, offsetBy: payloadLength) else { return nil }
        payload = Data(buffer[offset..<buffer.index(offset, offsetBy: payloadLength)])
        offset = buffer.index(offset, offsetBy: payloadLength)
    }

    let bytesConsumed = buffer.distance(from: buffer.startIndex, to: offset)
    return (WyomingEvent(type: type, data: data, payload: payload), bytesConsumed)
}

// MARK: - Audio helpers

struct AudioFormat {
    var rate: Int     // sample rate, e.g. 16000
    var width: Int    // bytes per sample, e.g. 2 (int16)
    var channels: Int // channel count, e.g. 1
}

extension AudioFormat {
    static let wyomingDefault = AudioFormat(rate: 16000, width: 2, channels: 1)

    init?(eventData data: [String: Any]) {
        guard let rate = data["rate"] as? Int ?? (data["rate"] as? NSNumber)?.intValue,
              let width = data["width"] as? Int ?? (data["width"] as? NSNumber)?.intValue,
              let channels = data["channels"] as? Int ?? (data["channels"] as? NSNumber)?.intValue
        else { return nil }
        self.rate = rate
        self.width = width
        self.channels = channels
    }

    var eventData: [String: Any] {
        ["rate": rate, "width": width, "channels": channels]
    }
}

// MARK: - Convenience builders

extension WyomingEvent {
    static func transcript(text: String, language: String? = nil) -> WyomingEvent {
        var data: [String: Any] = ["text": text]
        if let lang = language { data["language"] = lang }
        return WyomingEvent(type: WyomingEventType.transcript, data: data)
    }

    static func transcriptChunk(text: String) -> WyomingEvent {
        WyomingEvent(type: WyomingEventType.transcriptChunk, data: ["text": text])
    }

    static func info(name: String, description: String, languages: [String], version: String) -> WyomingEvent {
        let asrInfo: [[String: Any]] = [[
            "name": name,
            "description": description,
            "languages": languages,
            "attribution": ["name": "Apple", "url": "https://developer.apple.com/documentation/speech"],
            "installed": true,
            "version": version,
        ]]
        return WyomingEvent(type: WyomingEventType.info, data: ["asr": asrInfo])
    }

    static func error(text: String, code: String? = nil) -> WyomingEvent {
        var data: [String: Any] = ["text": text]
        if let code = code { data["code"] = code }
        return WyomingEvent(type: WyomingEventType.error, data: data)
    }

    static func pong() -> WyomingEvent {
        WyomingEvent(type: WyomingEventType.pong, data: [:])
    }
}
