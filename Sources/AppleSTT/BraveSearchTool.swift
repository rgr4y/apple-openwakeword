// BraveSearchTool: brave_web_search and brave_local_search via Brave LLM Context API.
// Both tools hit /res/v1/llm/context — richer extracted content vs raw snippets.
// Location headers are always sent; local recall auto-enables for local queries.

import Foundation

// Shared rate limiter — Brave free tier: 1 req/sec.
private actor BraveRateLimiter {
    static let shared = BraveRateLimiter()
    private var lastCall: Date = .distantPast
    private let minInterval: TimeInterval = 1.0

    func waitIfNeeded() async {
        let elapsed = Date().timeIntervalSince(lastCall)
        if elapsed < minInterval {
            try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
        }
        lastCall = Date()
    }
}

final class BraveSearchTool: LLMTool {
    private let apiKey: String
    private let toolName: String
    private let toolDescription: String
    private let session = URLSession.shared

    init(name: String, description: String, apiKey: String) {
        self.toolName = name
        self.toolDescription = description
        self.apiKey = apiKey
    }

    // MARK: - LLMTool

    var definition: [String: Any] {[
        "function": [
            "name": toolName,
            "description": toolDescription,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search query.",
                    ],
                    "count": [
                        "type": "integer",
                        "description": "Number of sources to consider (default 5, max 20).",
                    ],
                ],
                "required": ["query"],
            ],
        ]
    ]}

    func execute(arguments: [String: Any]) async -> String {
        guard let query = arguments["query"] as? String else {
            return "Error: missing 'query' argument"
        }
        let count = min(arguments["count"] as? Int ?? 5, 20)
        return await llmContextSearch(query: query, count: count)
    }

    func matches(_ input: String) -> Bool { false }

    // MARK: - Brave LLM Context API

    private func llmContextSearch(query: String, count: Int) async -> String {
        guard let url = URL(string: "https://api.search.brave.com/res/v1/llm/context") else {
            return "Error: invalid URL"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 15

        // Location headers — auto-enables local recall for local queries
        request.setValue("35.3404", forHTTPHeaderField: "X-Loc-Lat")
        request.setValue("-119.0784", forHTTPHeaderField: "X-Loc-Long")
        request.setValue("Bakersfield", forHTTPHeaderField: "X-Loc-City")
        request.setValue("CA", forHTTPHeaderField: "X-Loc-State")
        request.setValue("California", forHTTPHeaderField: "X-Loc-State-Name")
        request.setValue("US", forHTTPHeaderField: "X-Loc-Country")
        request.setValue("93309", forHTTPHeaderField: "X-Loc-Postal-Code")

        let body: [String: Any] = [
            "q": query,
            "count": count,
            "maximum_number_of_tokens": 2048,
            "maximum_number_of_snippets": 10,
            "context_threshold_mode": "balanced",
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Error: failed to encode request"
        }
        request.httpBody = jsonData

        log("BraveSearch llm-context: \(query)", debug: true)
        await BraveRateLimiter.shared.waitIfNeeded()

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                log("BraveSearch HTTP \(http.statusCode): \(body)")
                return "Error: Brave Search returned HTTP \(http.statusCode)"
            }
            return parseContextResults(data)
        } catch {
            log("BraveSearch failed: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Parser

    private func parseContextResults(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grounding = json["grounding"] as? [String: Any] else {
            return "No results found."
        }

        var lines: [String] = []

        // POI result (local business)
        if let poi = grounding["poi"] as? [String: Any],
           let name = poi["name"] as? String, !name.isEmpty {
            let snippets = (poi["snippets"] as? [String] ?? []).prefix(2).joined(separator: " ")
            lines.append("[\(name)] \(snippets)")
        }

        // Map results (local places)
        if let map = grounding["map"] as? [[String: Any]] {
            for place in map.prefix(3) {
                guard let name = place["name"] as? String, !name.isEmpty else { continue }
                let snippets = (place["snippets"] as? [String] ?? []).prefix(1).joined(separator: " ")
                lines.append("[\(name)] \(snippets)")
            }
        }

        // Generic web results
        if let generic = grounding["generic"] as? [[String: Any]] {
            for result in generic.prefix(max(0, 5 - lines.count)) {
                let title = result["title"] as? String ?? ""
                let snippets = (result["snippets"] as? [String] ?? []).prefix(2).joined(separator: " ")
                guard !snippets.isEmpty else { continue }
                lines.append(title.isEmpty ? snippets : "[\(title)] \(snippets)")
            }
        }

        return lines.isEmpty ? "No results found." : lines.joined(separator: "\n")
    }
}
