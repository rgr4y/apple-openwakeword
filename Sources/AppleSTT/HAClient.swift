// HAClient: Home Assistant REST API client, exposed as an LLM tool.
// Uses /api/conversation/process — HA's built-in NLP handles device matching.

import Foundation

final class HAClient: LLMTool {
    private let baseURL: URL
    private let token: String
    private let session = URLSession.shared
    private let language: String

    init(host: String, token: String, language: String = "en") {
        self.baseURL = URL(string: host)!
        self.token = token
        self.language = language
    }

    // MARK: - LLMTool conformance

    var definition: [String: Any] {
        [
            "function": [
                "name": "home_assistant",
                "description": "Control smart home devices via Home Assistant. Use for turning lights on/off, adjusting thermostats, locking doors, checking device states, running automations, etc.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "Natural language command for Home Assistant, e.g. 'turn off the kitchen lights' or 'set thermostat to 72'",
                        ]
                    ],
                    "required": ["command"],
                ],
            ]
        ]
    }

    func execute(arguments: [String: Any]) async -> String {
        guard let command = arguments["command"] as? String else {
            return "Error: missing 'command' argument"
        }
        return await conversationProcess(text: command)
    }

    func matches(_ input: String) -> Bool {
        let lower = input.lowercased()
        // Action verbs/phrases
        let actions = ["turn on", "turn off", "switch on", "switch off",
                       "set ", "dim ", "brighten ", "lock ", "unlock ",
                       "open ", "close ", "activate ", "deactivate ",
                       "run ", "trigger ", "enable ", "disable ",
                       "increase ", "decrease ", "raise ", "lower "]
        // Device/area keywords
        let devices = ["light", "lamp", "fan", "heat", "thermostat", "ac",
                       "air conditioner", "door", "lock", "blind", "shade",
                       "switch", "plug", "outlet", "scene", "automation",
                       "alarm", "garage", "cover", "curtain", "tv",
                       "bedroom", "kitchen", "bathroom", "living room",
                       "office", "hallway", "basement", "desk"]
        let hasAction = actions.contains { lower.hasPrefix($0) || lower.contains(" \($0)") }
            // Also catch ASR-dropped "turn": bare "on/off" at start or after punctuation
            || lower.hasPrefix("on ") || lower.hasPrefix("off ")
        let hasDevice = devices.contains { lower.contains($0) }
        return hasAction && hasDevice
    }

    // MARK: - HA REST API

    /// POST /api/conversation/process — sends natural language to HA's conversation agent.
    private func conversationProcess(text: String) async -> String {
        let url = baseURL.appendingPathComponent("/api/conversation/process")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "text": text,
            "language": language,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Error: failed to encode request"
        }
        request.httpBody = jsonData

        log("HA: conversation/process → \"\(text)\"", debug: true)

        do {
            let (data, httpResponse) = try await session.data(for: request)
            if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                log("HA HTTP \(http.statusCode): \(body)")
                return "Home Assistant returned an error (HTTP \(http.statusCode))"
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? [String: Any],
                  let speech = response["speech"] as? [String: Any],
                  let plain = speech["plain"] as? [String: Any],
                  let speechText = plain["speech"] as? String else {
                log("HA: unexpected response format")
                return "Home Assistant command executed but returned no response text."
            }

            log("HA response: \(speechText)")
            return speechText
        } catch {
            log("HA request failed: \(error)")
            return "Error: could not reach Home Assistant — \(error.localizedDescription)"
        }
    }
}
