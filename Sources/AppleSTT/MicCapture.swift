// AVAudioEngine-based microphone capture.
// Captures from the default input device (or a pinned device), resamples to
// 16 kHz mono Float32, and calls the sample handler on every chunk.
// Re-entrant: call restart() when the device changes.

import AudioToolbox   // kAudioOutputUnitProperty_CurrentDevice
import AVFoundation
import CoreAudio      // AudioDeviceID
import Foundation

final class MicCapture {
    typealias SampleHandler = ([Float]) -> Void

    private var engine: AVAudioEngine?
    private(set) var isRunning = false
    private let onSamples: SampleHandler
    private let targetSampleRate: Double = 16_000.0
    /// When non-nil, pins the engine to this specific CoreAudio device instead of
    /// the system default.
    let deviceID: AudioDeviceID?
    /// Human-readable label used in log messages.
    let deviceLabel: String

    init(deviceID: AudioDeviceID? = nil, label: String = "default", onSamples: @escaping SampleHandler) {
        self.deviceID = deviceID
        self.deviceLabel = label
        self.onSamples = onSamples
    }

    // MARK: - Start / Stop

    func start() throws {
        stop()
        let eng = AVAudioEngine()
        engine = eng

        let node = eng.inputNode

        // Pin to a specific device if requested (macOS only).
        // Must be done before installing the tap / starting the engine.
        if let devID = deviceID, let au = node.audioUnit {
            var id = devID
            let status = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                log("MicCapture[\(deviceLabel)]: failed to pin device id=\(devID), OSStatus=\(status)")
            }
        }

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
        log("MicCapture[\(deviceLabel)]: started (\(tapFormat.sampleRate)Hz \(tapFormat.channelCount)ch → 16kHz mono)", debug: true)
    }

    func stop() {
        guard isRunning || engine != nil else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        log("MicCapture[\(deviceLabel)]: stopped", debug: true)
    }

    func restart() throws {
        log("MicCapture[\(deviceLabel)]: restarting (device change)", debug: true)
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

/// Requests microphone access, then polls every 2 seconds in case the user
/// grants it via System Settings. Gives up after `maxRetries` polls and exits.
func ensureMicrophoneAccess(maxRetries: Int = 3) async {
    // First, trigger the system request dialog (works if notDetermined)
    let initial = AVCaptureDevice.authorizationStatus(for: .audio)

    if initial == .notDetermined {
        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        if granted {
            log("Microphone access granted")
            return
        }
        // Prompt shown but denied — fall through to retry loop
    } else if initial == .authorized {
        log("Microphone access already granted")
        return
    }

    // Status is denied or restricted. Print instructions and poll.
    log("Microphone access not granted (status=\(initial.rawValue))")
    log("→ Open: System Settings → Privacy & Security → Microphone → enable for Terminal/iTerm2")

    for attempt in 1...maxRetries {
        log("Waiting 2s… (check \(attempt)/\(maxRetries))", debug: true)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            log("Microphone access granted")
            return
        }
        if status == .notDetermined {
            // Try requesting again (happens after a TCC DB reset)
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            if granted {
                log("Microphone access granted")
                return
            }
        }
        log("Still not granted (status=\(status.rawValue))")
    }

    log("ERROR: microphone access denied after \(maxRetries) retries. Exiting.")
    exit(1)
}
