// Simple logging utility.
// Goes to stderr so stdout can be used for JSON transcript lines.

import Foundation

private var _debugEnabled = false

func logSetDebug(_ enabled: Bool) {
    _debugEnabled = enabled
}

func log(_ message: String, debug: Bool = false) {
    if debug && !_debugEnabled { return }
    let ts = DateFormatter.localizedString(
        from: Date(),
        dateStyle: .none,
        timeStyle: .medium
    )
    fputs("[\(ts)] \(message)\n", stderr)
}
