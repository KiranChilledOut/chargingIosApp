import Foundation

public struct WebSearchResult: Sendable, Equatable, Identifiable {
    public let title: String
    public let url: String
    public let snippet: String

    public var id: String { url }

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct WebSearchResponse: Sendable, Equatable {
    public let query: String
    /// Tavily's own synthesis, when asked for.
    public let answer: String
    public let results: [WebSearchResult]

    public init(query: String, answer: String = "", results: [WebSearchResult] = []) {
        self.query = query
        self.answer = answer
        self.results = results
    }

    public var isEmpty: Bool { answer.isEmpty && results.isEmpty }

    /// The findings as grounding for the model.
    ///
    /// Dated explicitly, and told to prefer this over recall. Prices, rates and
    /// benefit thresholds are exactly the things a model states confidently and
    /// out of date, and exactly the things someone asks about a Dutch contract
    /// screen.
    public func grounding(asOf date: Date = Date()) -> String {
        guard !isEmpty else { return "" }

        let stamp = DateFormatter.searchStamp.string(from: date)
        var lines = [
            "Web search results for \"\(query)\", retrieved \(stamp). "
                + "Prefer these over anything you remember, and say when a figure comes from here.",
        ]
        if !answer.isEmpty {
            lines.append("Summary: \(answer)")
        }
        for result in results {
            lines.append("- \(result.title) — \(result.url)\n  \(result.snippet)")
        }
        return lines.joined(separator: "\n")
    }
}

/// What happened to the lookup, so the interface can say rather than leave the
/// user guessing whether the feature works at all.
public enum SearchStatus: Sendable, Equatable {
    /// Off by setting, or not warranted for this turn.
    case skipped
    /// No key configured.
    case unavailable
    case failed(String)
    case searched(count: Int)

    public var didSearch: Bool {
        if case .searched = self { return true }
        return false
    }

    /// Short line for the interface. Nil when there is nothing worth saying —
    /// a successful search already shows its sources.
    public var note: String? {
        switch self {
        case .skipped: return nil
        case .unavailable: return "No Tavily key — answered from the screen only"
        case .failed(let reason): return "Search failed: \(reason)"
        case .searched: return nil
        }
    }
}

public enum WebSearchError: Swift.Error, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case serverError(status: Int)
    case invalidResponse

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "No Tavily API key set. Add one in Settings to look things up."
        case .unauthorized:
            return "Tavily rejected the API key. Paste the key itself (it starts with tvly-), not the whole MCP URL."
        case .rateLimited:
            return "Tavily rate limit reached. Try again shortly."
        case .serverError(let status):
            return "Tavily server error (\(status))."
        case .invalidResponse:
            return "Unexpected response from Tavily."
        }
    }
}

/// Looks things up on the web so answers can rest on current figures.
public struct TavilyClient: Sendable {

    public static let defaultBaseURL = URL(string: "https://api.tavily.com")!

    private let apiKey: String
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(
        apiKey: String,
        baseURL: URL = TavilyClient.defaultBaseURL,
        transport: any HTTPTransport = URLSessionTransport(),
        timeout: TimeInterval = 20
    ) {
        self.apiKey = Self.normalizeKey(apiKey)
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
    }

    public var isUsable: Bool { !apiKey.isEmpty }

    /// Pulls a usable key out of whatever was pasted.
    ///
    /// Tavily hands out an MCP URL with the key embedded in it, so that URL is
    /// what people copy — and pasting it whole produces
    /// "Unauthorized: missing or invalid API key", which reads as a bad key
    /// rather than the wrong *kind* of value. Quotes do the same, and come
    /// along free from any copy that grabbed a surrounding string literal.
    ///
    /// Demanding the bare key was friction with no upside: the key is right
    /// there in the URL, and extracting it is this function's job rather than
    /// the user's.
    public static func normalizeKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // A URL — take the query parameter out of it.
        if value.lowercased().hasPrefix("http"),
           let components = URLComponents(string: value),
           let key = components.queryItems?.first(where: {
               $0.name.lowercased() == "tavilyapikey" || $0.name.lowercased() == "api_key"
           })?.value {
            value = key
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this looks like a Tavily key at all, so a wrong-kind-of-value
    /// can be named as such instead of arriving as a bare auth failure.
    public static func looksLikeKey(_ raw: String) -> Bool {
        normalizeKey(raw).lowercased().hasPrefix("tvly-")
    }

    public func search(
        _ query: String,
        maxResults: Int = 5,
        depth: String = "basic"
    ) async throws -> WebSearchResponse {
        guard isUsable else { throw WebSearchError.missingAPIKey }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return WebSearchResponse(query: query) }

        let payload: [String: Any] = [
            "query": trimmed,
            "search_depth": depth,
            "max_results": maxResults,
            "include_answer": true,
        ]

        let request = HTTPRequest(
            url: baseURL.appendingPathComponent("search"),
            method: "POST",
            headers: [
                // Bearer, not an `api_key` body field. Tavily deprecated the
                // body form and newer keys reject it outright — a mistake that
                // fails as an auth error with nothing pointing at the cause.
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
            ],
            body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            timeout: timeout
        )

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapStatus(response.statusCode)
        }
        return try Self.parse(response.body, query: trimmed)
    }

    static func mapStatus(_ status: Int) -> WebSearchError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .serverError(status: status)
        }
    }

    static func parse(_ body: Data, query: String) throws -> WebSearchResponse {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw WebSearchError.invalidResponse
        }

        let answer = (root["answer"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let results = (root["results"] as? [[String: Any]] ?? []).compactMap {
            item -> WebSearchResult? in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            return WebSearchResult(
                title: (item["title"] as? String) ?? url,
                url: url,
                snippet: Self.condense((item["content"] as? String) ?? "")
            )
        }

        return WebSearchResponse(query: query, answer: answer, results: results)
    }

    /// Trims a page extract to something worth spending tokens on.
    static func condense(_ text: String, limit: Int = 400) -> String {
        let clean = TextNormalization.collapseWhitespace(text)
        guard clean.count > limit else { return clean }

        let cut = clean.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}

extension DateFormatter {
    static let searchStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()
}
