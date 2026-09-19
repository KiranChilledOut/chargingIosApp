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

    /// What the model is told about the lookup, when there is anything to say.
    ///
    /// Without this the model receives an empty grounding string and no
    /// explanation, so it accounts for the gap itself — and what it says is
    /// "I don't have a search tool connected in this conversation", which is
    /// both wrong and unfixable-sounding. The app *does* search; this turn's
    /// lookup failed. Saying so gets an answer that flags its own staleness
    /// instead of disowning a feature the user paid attention to setting up.
    public var modelNote: String {
        switch self {
        case .searched, .skipped:
            return ""
        case .unavailable:
            return "No web lookup ran for this question because no search key is "
                + "configured. Answer from the screen and from what you know. If the "
                + "answer turns on a figure that changes yearly — a rate, a threshold, "
                + "a price — say that it should be checked against a current source. "
                + "Do not say you are unable to search; the app can, once a key is set."
        case .failed(let reason):
            return "A web lookup was attempted for this question and failed (\(reason)). "
                + "Answer from the screen and from what you know, and say plainly that "
                + "you could not check current sources this time, so any rate, threshold "
                + "or price may be out of date. Do not say you have no search tool — the "
                + "app has one and it failed on this turn."
        }
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
    /// 432 plan limit, 433 pay-as-you-go limit. A working key with nothing
    /// left on it, which is not the same problem as a wrong key and must not
    /// be reported as one.
    case outOfCredits(message: String)
    case rateLimited
    case serverError(status: Int, message: String)
    case invalidResponse

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "No Tavily API key set. Add one in Settings to look things up."
        case .unauthorized:
            // Tavily answers every bad-key case with the same 401 and the same
            // body — rotated, mistyped, wrong account, no header at all. The
            // response cannot tell them apart, so neither can this message;
            // asserting one cause just sends people to fix the wrong thing.
            return "Tavily did not accept this key. Tap “Test key” in Settings to check it."
        case .outOfCredits(let message):
            return message.isEmpty
                ? "Tavily credits are used up for this plan."
                : "Tavily: \(message)"
        case .rateLimited:
            return "Tavily rate limit reached. Try again shortly."
        case .serverError(let status, let message):
            return message.isEmpty
                ? "Tavily server error (\(status))."
                : "Tavily server error (\(status)): \(message)"
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
            throw Self.mapStatus(response.statusCode, body: response.body)
        }
        return try Self.parse(response.body, query: trimmed)
    }

    static func mapStatus(_ status: Int, body: Data = Data()) -> WebSearchError {
        let message = Self.errorMessage(from: body)
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        // 432 is a plan limit, 433 a pay-as-you-go ceiling. Both are documented
        // and both mean the key is fine — lumping them in with a server error
        // would hide the one fact that explains the failure.
        case 432, 433: return .outOfCredits(message: message)
        default: return .serverError(status: status, message: message)
        }
    }

    /// Tavily's own reason for refusing, when it gave one.
    ///
    /// The shape is `{"detail": {"error": "..."}}` — `detail` is an object
    /// here, not the string Nebius returns, so the two cannot share an
    /// extractor.
    static func errorMessage(from body: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return "" }

        if let detail = root["detail"] as? [String: Any],
           let error = detail["error"] as? String {
            return error
        }
        if let detail = root["detail"] as? String { return detail }
        if let error = root["error"] as? String { return error }
        if let message = root["message"] as? String { return message }
        return ""
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

// MARK: - Checking a key

/// What a key actually does when it is used.
///
/// Tavily answers every bad-key case with an identical 401 and an identical
/// body, so a failed search can never say *why* it failed. The only way to
/// tell a rotated key from a mistyped one from an exhausted plan is to try it
/// and look at the whole picture — status code, the server's own words, and
/// the shape of what is stored. That is what this carries.
public struct TavilyKeyCheck: Sendable, Equatable {

    public enum Outcome: Sendable, Equatable {
        case working(resultCount: Int)
        /// Nothing stored at all.
        case noKey
        /// Something is stored, but it is not a key. Carries what it looks
        /// like instead, because "invalid" alone never tells anyone what to do.
        case notAKey(looksLike: String)
        /// A well-formed key Tavily does not recognise.
        case rejected
        /// 432/433 — the key is fine, the plan is not.
        case outOfCredits
        case rateLimited
        case serverError(status: Int)
        case unreachable(String)
    }

    public let outcome: Outcome
    /// Tavily's own words, quoted rather than paraphrased.
    public let serverMessage: String

    public init(outcome: Outcome, serverMessage: String = "") {
        self.outcome = outcome
        self.serverMessage = serverMessage
    }

    public var isWorking: Bool {
        if case .working = outcome { return true }
        return false
    }

    public var headline: String {
        switch outcome {
        case .working(let count):
            return count > 0
                ? "Key works — \(count) result\(count == 1 ? "" : "s") back from Tavily"
                : "Key works"
        case .noKey:
            return "No key saved"
        case .notAKey(let looksLike):
            return "That is not a key — it looks like \(looksLike)"
        case .rejected:
            return "Tavily does not recognise this key"
        case .outOfCredits:
            return "Key is valid, but the plan has no credits left"
        case .rateLimited:
            return "Rate limited — the key is valid"
        case .serverError(let status):
            return "Tavily is having trouble (\(status))"
        case .unreachable:
            return "Could not reach Tavily"
        }
    }

    /// What to do about it. Nil when there is nothing to do.
    public var advice: String? {
        switch outcome {
        case .working, .rateLimited:
            return nil
        case .noKey:
            return "Paste your key above — the whole MCP URL works too."
        case .notAKey:
            return "Copy the key from tavily.com; it starts with tvly-."
        case .rejected:
            // Every one of these produces the same 401, so all three are named
            // rather than picking one and sending them down the wrong path.
            return "Keys read the same to Tavily whether they were rotated, "
                + "mistyped, or belong to a different account. Check the key on "
                + "tavily.com matches the one shown here, and paste a fresh one if not."
        case .outOfCredits:
            return "Top up or upgrade at tavily.com. Nothing is wrong with the app."
        case .serverError:
            return "Not your key — try again in a few minutes."
        case .unreachable(let reason):
            return reason
        }
    }
}

extension TavilyClient {

    /// Runs one real search to find out what the key actually does.
    ///
    /// Deliberately a real request: the only failure worth reporting is the
    /// one that happens on the wire, and a format check would have called the
    /// rotated key that caused all this perfectly fine. Costs one credit.
    public func check() async -> TavilyKeyCheck {
        guard isUsable else { return TavilyKeyCheck(outcome: .noKey) }
        guard Self.looksLikeKey(apiKey) else {
            return TavilyKeyCheck(outcome: .notAKey(looksLike: Self.shape(of: apiKey)))
        }

        do {
            let response = try await search("Tavily key check", maxResults: 1)
            return TavilyKeyCheck(outcome: .working(resultCount: response.results.count))
        } catch let error as WebSearchError {
            switch error {
            case .unauthorized:
                return TavilyKeyCheck(outcome: .rejected)
            case .outOfCredits(let message):
                return TavilyKeyCheck(outcome: .outOfCredits, serverMessage: message)
            case .rateLimited:
                return TavilyKeyCheck(outcome: .rateLimited)
            case .serverError(let status, let message):
                return TavilyKeyCheck(outcome: .serverError(status: status), serverMessage: message)
            case .missingAPIKey:
                return TavilyKeyCheck(outcome: .noKey)
            case .invalidResponse:
                return TavilyKeyCheck(outcome: .serverError(status: 200),
                                      serverMessage: "unreadable response")
            }
        } catch {
            return TavilyKeyCheck(outcome: .unreachable(error.localizedDescription))
        }
    }

    /// Names what a non-key actually is, so the interface can say so.
    static func shape(of value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "nothing" }
        if trimmed.lowercased().hasPrefix("http") { return "a web address" }
        if trimmed.contains(" ") { return "a sentence" }
        return "ordinary text"
    }

    /// Enough of the stored key to compare against the dashboard, and no more.
    ///
    /// Without this there is no way to tell a rotated key from the right one:
    /// both fail identically, and the field in Settings starts empty on every
    /// launch, so it cannot be checked by looking.
    public static func preview(of raw: String) -> String {
        let key = normalizeKey(raw)
        guard !key.isEmpty else { return "nothing saved" }
        guard key.count > 14 else { return "\(key.count) characters — too short for a key" }

        let head = key.prefix(10)
        let tail = key.suffix(4)
        return "\(head)…\(tail) · \(key.count) characters"
    }
}
