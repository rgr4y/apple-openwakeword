import Foundation

let config = Config.parse()
logSetDebug(config.debug)

let daemon = Daemon(config: config)

Task { @MainActor in
    await daemon.run()
}

// Keep the process alive; run loop handles all I/O and timers.
RunLoop.main.run()
