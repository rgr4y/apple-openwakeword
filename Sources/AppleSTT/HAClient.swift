// HAClient: Home Assistant REST API client, exposed as an LLM tool.
// Uses /api/conversation/process — HA's built-in NLP handles device matching.

import Foundation

final class HAClient: LLMTool {
    private let baseURL: URL
    private let token: String
    private let session = URLSession.shared
    private let language: String
    private let agentId: String?

    init(host: String, token: String, language: String = "en", agentId: String? = nil) {
        self.baseURL = URL(string: host)!
        self.token = token
        self.language = language
        self.agentId = agentId
    }

    // MARK: - LLMTool conformance

    var definition: [String: Any] {
        [
            "function": [
                "name": "home_assistant",
                "description": "Send a natural language command to Home Assistant. The ONLY parameter is 'command' — a complete English sentence. HA handles all device matching and service routing internally. Examples: 'turn off the kitchen lights', 'what switches are currently on?', 'set the thermostat to 72 degrees', 'lock the front door'. NEVER pass 'service', 'entity_id', or HA service names as parameters. Send ONE command per question — do not make separate calls per device.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "A complete English sentence describing what to do or ask. E.g. 'which lights are on in the bedroom?' or 'turn off all the switches'.",
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
        let result = await conversationProcess(text: command)
        return trimConfirmation(result)
    }

    /// HA confirmation responses are verbose ("Done. I have turned off the X.").
    /// For voice, just "Done." is enough.
    private func trimConfirmation(_ text: String) -> String {
        if text.hasPrefix("Done.") { return "Done." }
        if text.hasPrefix("Turned on") || text.hasPrefix("Turned off") { return "Done." }
        if text.hasPrefix("I've turned") || text.hasPrefix("I have turned") { return "Done." }
        return text
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

        var body: [String: Any] = [
            "text": text,
            "language": language,
        ]
        if let agentId {
            body["agent_id"] = agentId
        }

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

            log("HA response: \(speechText)", debug: true)
            return speechText
        } catch {
            log("HA request failed: \(error)")
            return "Error: could not reach Home Assistant — \(error.localizedDescription)"
        }
    }

    // MARK: - LLM context from exposed entities

    /// Fetches entities exposed to the conversation assistant via the WebSocket API,
    /// then retrieves their friendly names via REST. Returns a formatted device list
    /// suitable for appending to the local LLM system prompt.
    func fetchConversationContext() async -> String? {
        log("HA: fetching exposed entities for LLM context...", debug: true)
        guard let exposedIds = await fetchExposedEntityIds() else {
            log("HA: fetchExposedEntityIds returned nil — WS fetch failed")
            return nil
        }
        guard !exposedIds.isEmpty else {
            log("HA: no entities are exposed to the conversation assistant")
            return nil
        }
        log("HA: \(exposedIds.count) entities exposed to conversation assistant", debug: true)

        let entities = await fetchEntityInfo(ids: exposedIds)
        guard !entities.isEmpty else {
            log("HA: fetchEntityInfo returned no results")
            return nil
        }

        // Group by domain, human-readable. Avoid HA service syntax ("domain: X") which
        // causes the LLM to fabricate service/entity_id params instead of using 'command'.
        var byDomain: [String: [String]] = [:]
        for e in entities {
            byDomain[e.domain, default: []].append(e.name)
        }
        var lines = [
            "Known smart home devices (ALWAYS pass plain English to home_assistant — never use service names or entity IDs):"
        ]
        for domain in byDomain.keys.sorted() {
            let names = byDomain[domain]!.sorted().joined(separator: ", ")
            let label = domain.prefix(1).uppercased() + domain.dropFirst()
            lines.append("\(label)s: \(names)")
        }
        let context = lines.joined(separator: "\n")
        log("HA: LLM context built — \(entities.count) devices")
        return context
    }

    // MARK: - Private WS/REST helpers

    private struct EntityInfo {
        let entityId: String
        let domain: String
        let name: String
    }

    private func fetchExposedEntityIds() async -> [String]? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        components.path = "/api/websocket"
        guard let wsURL = components.url else {
            log("HA WS: could not build WebSocket URL from \(baseURL)")
            return nil
        }
        log("HA WS: connecting to \(wsURL)", debug: true)

        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        for step in 0..<6 {
            let msg: URLSessionWebSocketTask.Message
            do { msg = try await task.receive() }
            catch { log("HA WS: receive error at step \(step): \(error)"); return nil }

            guard case .string(let text) = msg,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = json["type"] as? String else {
                log("HA WS: unexpected non-string message at step \(step)", debug: true)
                continue
            }

            log("HA WS: step \(step) type=\(type_)", debug: true)

            switch type_ {
            case "auth_required":
                let auth: [String: Any] = ["type": "auth", "access_token": token]
                guard let d = try? JSONSerialization.data(withJSONObject: auth),
                      let s = String(data: d, encoding: .utf8) else { return nil }
                do { try await task.send(.string(s)) }
                catch { log("HA WS: failed to send auth: \(error)"); return nil }

            case "auth_ok":
                let q: [String: Any] = ["id": 1, "type": "homeassistant/expose_entity/list"]
                guard let d = try? JSONSerialization.data(withJSONObject: q),
                      let s = String(data: d, encoding: .utf8) else { return nil }
                do { try await task.send(.string(s)) }
                catch { log("HA WS: failed to send query: \(error)"); return nil }

            case "result":
                if let success = json["success"] as? Bool, !success {
                    log("HA WS: result success=false: \(json["error"] ?? "unknown error")")
                    return nil
                }
                guard let result = json["result"] as? [String: Any],
                      let exposed = result["exposed_entities"] as? [String: Any] else {
                    log("HA WS: result has unexpected shape — keys: \(json.keys.sorted())")
                    return nil
                }
                let ids = exposed.compactMap { (id, val) -> String? in
                    guard let dict = val as? [String: Any],
                          dict["conversation"] as? Bool == true else { return nil }
                    return id
                }
                log("HA WS: found \(ids.count) conversation-exposed entity IDs", debug: true)
                return ids

            case "auth_invalid":
                log("HA WS: auth_invalid — check HA token"); return nil
            default:
                log("HA WS: unhandled type=\(type_)", debug: true)
            }
        }
        log("HA WS: exhausted 6 receive attempts without getting a result")
        return nil
    }

    private func fetchEntityInfo(ids: [String]) async -> [EntityInfo] {
        let url = baseURL.appendingPathComponent("/api/states")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log("HA REST /api/states returned HTTP \(http.statusCode)")
                return []
            }
            guard let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("HA REST /api/states: could not parse response")
                return []
            }
            let idSet = Set(ids)
            return all.compactMap { state -> EntityInfo? in
                guard let entityId = state["entity_id"] as? String,
                      idSet.contains(entityId) else { return nil }
                let domain = String(entityId.split(separator: ".").first ?? "unknown")
                let attrs = state["attributes"] as? [String: Any]
                let name = (attrs?["friendly_name"] as? String) ?? entityId
                return EntityInfo(entityId: entityId, domain: domain, name: name)
            }
        } catch {
            log("HA REST /api/states failed: \(error)")
            return []
        }
    }
}
