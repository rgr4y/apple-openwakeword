import Foundation

let config = Config.parse()
logSetDebug(config.debug)

// Graceful shutdown on SIGINT/SIGTERM so the stop sound can play
var _daemon: Daemon?
func handleShutdown() {
    _daemon?.stopWakeWordClient()
    exit(0)
}
signal(SIGINT)  { _ in handleShutdown() }
signal(SIGTERM) { _ in handleShutdown() }

// Handle --list-mics before starting anything else.
if config.listMics {
    let devices = AudioDeviceMonitor.listInputDevices()
    if devices.isEmpty {
        print("No input devices found.")
    } else {
        print("Available input devices:")
        for (id, name) in devices {
            print("  [\(id)] \(name)")
        }
    }
    exit(0)
}

let daemon = Daemon(config: config)
_daemon = daemon

Task { @MainActor in
    await daemon.run()
}

// Keep the process alive; run loop handles all I/O and timers.
RunLoop.main.run()
