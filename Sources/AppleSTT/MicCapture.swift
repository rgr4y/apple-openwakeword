// AVAudioEngine-based microphone capture.
// Captures from the default input device, resamples to 16 kHz mono Float32,
// and calls the sample handler on every chunk.
// Re-entrant: call restart() when the device changes.

import AVFoundation
import Foundation

final class MicCapture {
    typealias SampleHandler = ([Float]) -> Void

    private var engine: AVAudioEngine?
    private(set) var isRunning = false
    private let onSamples: SampleHandler
    private let targetSampleRate: Double = 16_000.0

    init(onSamples: @escaping SampleHandler) {
        self.onSamples = onSamples
    }

    // MARK: - Start / Stop

    func start() throws {
        stop()
        let eng = AVAudioEngine()
        engine = eng

        let node = eng.inputNode
        let tapFormat = node.outputFormat(forBus: 0)

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let sourceSR = tapFormat.sampleRate
        let sourceCh = Int(tapFormat.channelCount)
        let handler = onSamples

        node.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.processBuffer(buffer, sourceSR: sourceSR, sourceCh: sourceCh, handler: handler)
        }

        try eng.start()
        isRunning = true
        log("MicCapture: started (\(tapFormat.sampleRate)Hz \(tapFormat.channelCount)ch → 16kHz mono)")
    }

    func stop() {
        guard isRunning || engine != nil else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        log("MicCapture: stopped")
    }

    func restart() throws {
        log("MicCapture: restarting (device change)")
        stop()
        try start()
    }

    // MARK: - Internal

    private func processBuffer(_ buffer: AVAudioPCMBuffer,
                               sourceSR: Double,
                               sourceCh: Int,
                               handler: SampleHandler) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return }

        // Mix down to mono
        let mono: [Float]
        if sourceCh > 1 {
            mono = (0..<frameCount).map { i in
                (0..<sourceCh).reduce(Float(0)) { $0 + floatData[$1][i] } / Float(sourceCh)
            }
        } else {
            mono = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        }

        // Resample to 16 kHz if needed
        let samples: [Float]
        if abs(sourceSR - targetSampleRate) < 1.0 {
            samples = mono
        } else {
            let ratio = sourceSR / targetSampleRate
            let outCount = max(1, Int(Double(mono.count) / ratio))
            var resampled = [Float]()
            resampled.reserveCapacity(outCount)
            var idx: Double = 0
            while Int(idx) < mono.count {
                resampled.append(mono[Int(idx)])
                idx += ratio
            }
            samples = resampled
        }

        handler(samples)
    }
}

enum CaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case permissionDenied

    var description: String {
        switch self {
        case .noInputDevice: return "No audio input device available"
        case .permissionDenied: return "Microphone access denied"
        }
    }
}

// MARK: - Permission helper

func requestMicrophoneAccess() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized: return true
    case .notDetermined:
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    default: return false
    }
}
