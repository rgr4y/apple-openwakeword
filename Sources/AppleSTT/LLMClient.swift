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

    init(endpoint: String, model: String, systemPrompt: String? = nil) {
        self.endpoint = URL(string: endpoint)!
        self.model = model
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
    }

    func registerTool(_ tool: LLMTool, name: String) {
        tools[name] = tool
    }

    /// Send a trivial message to /v1/chat/completions to verify the endpoint is up.
    func healthCheck() async {
        log("LLM healthcheck → \(endpoint.appendingPathComponent("/v1/chat/completions").absoluteString)")
        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are a helpful assistant. Keep replies very short."],
            ["role": "user", "content": "Reply with just the word 'ok'."],
        ]
        guard let response = await chatCompletion(messages: messages) else {
            log("LLM healthcheck FAILED — check that apfel is running at \(endpoint.absoluteString)")
            return
        }
        let reply = response["content"] as? String ?? "(no content)"
        log("LLM healthcheck OK — model=\(model) reply=\(reply.prefix(80))")
    }

    /// Send a user transcript to the LLM, handle tool calls, return final text response.
    func process(_ text: String) async -> String? {
        // Fast path: if a tool's keyword matcher fires, bypass the LLM for the action
        // then ask the LLM to phrase the result as a short spoken response.
        for (name, tool) in tools where tool.matches(text) {
            log("LLM fast-path: routing to \(name) (keyword match)")
            let result = await tool.execute(arguments: ["command": text])
            log("LLM fast-path result: \(result)")
            // Ask the model to turn the HA response into a natural spoken sentence
            let phrasing = await chatCompletion(messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
                ["role": "assistant", "content": "I'll handle that."],
                ["role": "user", "content": "The smart home returned: \"\(result)\". Phrase that as a short spoken confirmation, one sentence."],
            ])
            return (phrasing?["content"] as? String) ?? result
        }

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text],
        ]

        for _ in 0..<maxToolRounds {
            guard let response = await chatCompletion(messages: messages) else {
                return nil
            }

            // If the model wants to call tools, execute them and loop back
            if let toolCalls = response["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                // Append the assistant message with tool_calls
                messages.append(response)

                for call in toolCalls {
                    let id = call["id"] as? String ?? ""
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }

                    let argsString = function["arguments"] as? String ?? "{}"
                    let args = parseJSON(argsString)

                    let result: String
                    if let tool = tools[name] {
                        log("LLM tool call: \(name)(\(argsString))")
                        result = await tool.execute(arguments: args)
                    } else {
                        log("LLM requested unknown tool: \(name)")
                        result = "Error: tool '\(name)' is not available."
                    }

                    messages.append([
                        "role": "tool",
                        "tool_call_id": id,
                        "content": result,
                    ])
                }
                continue  // loop back to get the final response after tool results
            }

            // Plain text response — we're done
            if let content = response["content"] as? String, !content.isEmpty {
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

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = jsonData

        log("LLM request → \(url.absoluteString) (\(messages.count) messages)")

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

            let preview = (message["content"] as? String)?.prefix(80) ?? "(tool_call)"
            log("LLM response ← \(preview)")
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
    static let defaultSystemPrompt = "You are a helpful voice assistant running on a Mac. Keep responses concise and conversational — they will be spoken aloud via text-to-speech. Avoid markdown, bullet points, or formatting. If the user asks to control a smart home device, use the home_assistant tool. For general questions, just respond directly."
}
