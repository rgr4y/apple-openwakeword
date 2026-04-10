// CoreAudio-based default input device monitor.
// Fires onChange when the system default input device changes.
// Thread-safe: callback always dispatched on the provided queue.

import CoreAudio
import Foundation

final class AudioDeviceMonitor {
    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var isListening = false
    fileprivate let callbackQueue: DispatchQueue
    var onChange: (() -> Void)?

    init(queue: DispatchQueue = .main) {
        self.callbackQueue = queue
    }

    func start() {
        guard !isListening else { return }
        isListening = true

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceChangedCallback,
            selfPtr
        )
        if status != noErr {
            log("DeviceMonitor: failed to register listener, OSStatus=\(status)")
            Unmanaged<AudioDeviceMonitor>.fromOpaque(selfPtr).release()
            isListening = false
        } else {
            log("DeviceMonitor: listening for default input device changes")
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        // Note: ideally we'd remove the listener here, but we'd need the original selfPtr.
        // For a long-running daemon this is acceptable.
    }

    // MARK: - Current device info

    /// Returns the AudioDeviceID of the current default input device, or nil.
    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Returns the display name of a device, or nil.
    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (name as String?) : nil
    }

    /// Returns all input-capable devices as (AudioDeviceID, name) pairs.
    static func listInputDevices() -> [(AudioDeviceID, String)] {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = deviceName(id), hasInputChannels(id) else { return nil }
            return (id, name)
        }
    }

    /// Find the first input device whose name contains the given string (case-insensitive).
    /// Returns (AudioDeviceID, resolvedName) on match.
    static func findDevice(named: String) -> (AudioDeviceID, String)? {
        listInputDevices().first { $0.1.localizedCaseInsensitiveContains(named) }
    }

    // MARK: - Private helpers

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr) == noErr else { return false }
        let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
        return withUnsafeMutablePointer(to: &list.pointee.mBuffers) { basePtr in
            UnsafeBufferPointer(start: basePtr, count: Int(list.pointee.mNumberBuffers))
                .contains { $0.mNumberChannels > 0 }
        }
    }
}

// C-compatible callback — cannot capture self
private func deviceChangedCallback(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let ptr = clientData else { return noErr }
    let monitor = Unmanaged<AudioDeviceMonitor>.fromOpaque(ptr).takeUnretainedValue()
    monitor.callbackQueue.async {
        monitor.onChange?()
    }
    return noErr
}
