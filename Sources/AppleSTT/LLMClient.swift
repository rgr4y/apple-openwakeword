// LLMClient: OpenAI-compatible chat completions client with tool calling.
// Works with apfel, LM Studio, OpenAI, or any compatible endpoint.

import Foundation

// MARK: - Tool definition protocol

protocol LLMTool {
    /// JSON tool definition for the OpenAI tools array
    var definition: [String: Any] { get }
    /// Execute the tool with the given arguments JSON. Returns a result string.
    func execute(arguments: [String: Any]) async -> String
    /// Fast local check: does this input look like something this tool should handle?
    /// Return true to short-circuit the LLM and execute the tool directly.
    func matches(_ input: String) -> Bool
}

// MARK: - Client

final class LLMClient {
    private let endpoint: URL      // e.g. http://127.0.0.1:11434
    private let model: String
    private let systemPrompt: String
    private var tools: [String: LLMTool] = [:]
    private let session = URLSession.shared
    private let maxToolRounds = 5  // prevent infinite tool-call loops
    private var conversationHistory: [[String: Any]] = []
    private let maxHistoryTurns = 6  // last 3 exchanges

    private let integrations: [Any]

    init(endpoint: String, model: String, systemPrompt: String? = nil, integrations: [Any] = []) {
        self.endpoint = URL(string: endpoint)!
        self.model = model
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
        self.integrations = integrations
    }

    func registerTool(_ tool: LLMTool, name: String) {
        tools[name] = tool
    }

    /// Clear conversation history — call when a new wake word fires.
    func clearHistory() {
        conversationHistory = []
    }

    private func appendHistory(user: String, assistant: String) {
        conversationHistory.append(["role": "user", "content": user])
        conversationHistory.append(["role": "assistant", "content": assistant])
        if conversationHistory.count > maxHistoryTurns {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns))
        }
    }

    /// Send a trivial message to /v1/chat/completions to verify the endpoint is up.
    func healthCheck() async {
        log("LLM healthcheck → \(endpoint.appendingPathComponent("/v1/chat/completions").absoluteString)", debug: true)
        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are a helpful assistant. Keep replies very short."],
            ["role": "user", "content": "Reply with just the word 'ok'."],
        ]
        guard let response = await chatCompletion(messages: messages) else {
            log("LLM healthcheck FAILED — check that your local LLM is running at \(endpoint.absoluteString)")
            return
        }
        let reply = response["content"] as? String ?? "(no content)"
        log("LLM health OK — model=\(model) reply=\(reply.prefix(80).replacingOccurrences(of: "\n", with: ""))")
    }

    /// Send a user transcript to the LLM, handle tool calls, return final text response.
    func process(_ text: String) async -> String? {
        // Fast path: if a tool's keyword matcher fires, bypass the LLM for the action
        // then ask the LLM to phrase the result as a short spoken response.
        for (name, tool) in tools where tool.matches(text) {
            log("LLM fast-path: routing to \(name) (keyword match)", debug: true)
            let result = await tool.execute(arguments: ["command": text])
            log("LLM fast-path result: \(result)", debug: true)
            if result != "Done." { appendHistory(user: text, assistant: result) }
            return result
        }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages += conversationHistory
        messages.append(["role": "user", "content": text])

        for _ in 0..<maxToolRounds {
            guard let response = await chatCompletion(messages: messages) else {
                return nil
            }

            // If the model wants to call tools, execute them and loop back
            if let toolCalls = response["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                // Append the assistant message with tool_calls
                messages.append(response)
                var allDone = true

                for call in toolCalls {
                    let id = call["id"] as? String ?? ""
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }

                    let argsString = function["arguments"] as? String ?? "{}"
                    let args = parseJSON(argsString)

                    let result: String
                    if let tool = tools[name] {
                        log("LLM tool call: \(name)(\(argsString))", debug: true)
                        result = await tool.execute(arguments: args)
                        log("LLM tool result: \(String(result.prefix(300)))", debug: true)
                    } else {
                        log("LLM requested unknown tool: \(name)")
                        result = "Error: tool '\(name)' is not available."
                    }

                    messages.append([
                        "role": "tool",
                        "tool_call_id": id,
                        "content": result,
                    ])
                    if result != "Done." { allDone = false }
                }
                // If every tool returned a simple confirmation, skip the LLM rephrasing round
                if allDone { return "Done." }
                continue  // loop back to get the final response after tool results
            }

            // Plain text response — we're done
            if let content = response["content"] as? String, !content.isEmpty {
                appendHistory(user: text, assistant: content)
                return content
            }

            return nil
        }

        log("LLM: max tool rounds exceeded")
        return nil
    }

    // MARK: - HTTP

    private func chatCompletion(messages: [[String: Any]]) async -> [String: Any]? {
        let url = endpoint.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { (name, tool) -> [String: Any] in
                var def = tool.definition
                def["type"] = "function"
                return def
            }
        }

        if !integrations.isEmpty {
            body["integrations"] = integrations
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = jsonData

        log("LLM request → \(url.absoluteString) (\(messages.count) messages)", debug: true)

        do {
            let (data, httpResponse) = try await session.data(for: request)
            if let http = httpResponse as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                log("LLM HTTP \(http.statusCode): \(body)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else {
                let raw = String(data: data, encoding: .utf8) ?? "(binary)"
                log("LLM: unexpected response format — raw: \(raw.prefix(200))")
                return nil
            }

            return message
        } catch {
            log("LLM request failed: \(error)")
            return nil
        }
    }

    private func parseJSON(_ string: String) -> [String: Any] {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    // MARK: - Default system prompt
    // (override via llm.systemPrompt in config.json)
    
    static let defaultSystemPrompt = """
        You are a DIY Alexa-like assistant for Rob's smart home. Your responses are spoken aloud via \
        text-to-speech — keep them short, plain, and conversational. No markdown, bullet \
        points, or formatting. One or two sentences maximum.

        Most smart home commands (turn on/off, etc.) are handled automatically before \
        reaching you. If a home control request does reach you, use the home_assistant tool \
        to execute it. For questions about the current state of the home, use the \
        home_assistant tool to look it up. \

        IMPORTANT — home_assistant tool usage:
        - Pass a single 'command' parameter: a complete English sentence.
        - Example: "what switches are on?" or "turn off the bedroom lamp".
        - Send ONE command per question. Never make separate calls per device.
        - NEVER use 'service', 'entity_id', 'domain', or any HA-specific parameters.
        - HA handles all device matching internally.

        For general knowledge questions, answer directly from internal knowledge.

        You can use brave_web_search for up-to-date info from the web. Use this when
        the user asks about weather or current events. Use brave_local_search
        for data local to Rob's location, such as nearby restaurants or traffic.
        Rob is located in Bakersfield, CA 93309 — use this for local searches and weather.
        After returning search results, always offer a follow-up (e.g. directions, hours, phone number) and append REWAKE.

        If you genuinely can't understand a request, reply with "Huh? What?"

        If your response requires the user to answer a follow-up question, append the
        token REWAKE on its own at the very end of your response (after the question mark).
        The system will automatically re-open the microphone. Example:
        "I found three lights on. Which one do you want off? REWAKE"
        """
}
