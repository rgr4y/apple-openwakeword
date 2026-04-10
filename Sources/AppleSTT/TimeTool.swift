// TimeTool: returns the current local time and date as a spoken string.

import Foundation

final class TimeTool: LLMTool {

    var definition: [String: Any] {
        [
            "function": [
                "name": "get_time",
                "description": "Returns the current local time and date. Use this whenever the user asks what time it is, what day it is, or what the date is.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ],
            ]
        ]
    }

    func execute(arguments: [String: Any]) async -> String {
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateStyle = .none
        timeFmt.timeStyle = .short     // "11:38 PM"

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMMM d"  // "Wednesday, April 9"

        return "It's \(timeFmt.string(from: now)) on \(dateFmt.string(from: now))."
    }

    func matches(_ input: String) -> Bool {
        let t = input.lowercased()
        return t.contains("what time") || t.contains("what's the time")
            || t.contains("what day") || t.contains("what's the date")
            || t.contains("what is the time") || t.contains("what is the date")
            || t.contains("what is today") || t.contains("what's today")
    }
}
