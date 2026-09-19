import Foundation

/// The query to actually send, and whether it is worth sending.
public struct SearchPlan: Sendable, Equatable {
    public let query: String
    public let needsSearch: Bool
    /// Why, in a few words. Surfaced when a lookup is skipped, so "no search"
    /// is a visible decision rather than a silent one.
    public let reason: String

    public init(query: String, needsSearch: Bool = true, reason: String = "") {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.needsSearch = needsSearch
        self.reason = reason
    }

    public var isUsable: Bool { needsSearch && !query.isEmpty }
}

/// Turns a question into something a search engine can answer.
///
/// The first version sent the question verbatim. That works for the first
/// message and falls apart immediately afterwards, because follow-ups are
/// anaphoric — "is that a good rate?", "what's the average?", "should I
/// switch?" — and carry no topic at all. Sent alone, "what is the average
/// rate" against a Dutch energy contract came back with travel and entry
/// requirements: the engine had nothing to work with but the country.
///
/// The screen is right there, and so is everything already known about the
/// person. Both belong in the query.
public enum SearchQueryBuilder {

    /// Terms that make a query topical. Drawn from the domains these screens
    /// actually come from, in both languages, because the authoritative source
    /// for a Dutch rate is usually a Dutch-language page.
    static let domainTerms: Set<String> = [
        "stroom", "gas", "energie", "energierekening", "tarief", "tarieven",
        "kwh", "leveringskosten", "netbeheer", "vastrecht", "electricity",
        "energy", "tariff", "rate", "kilowatt",
        "huur", "huurtoeslag", "servicekosten", "rent", "rental", "landlord",
        "belasting", "belastingdienst", "aangifte", "toeslag", "toeslagen",
        "inkomstenbelasting", "loonheffing", "tax", "allowance", "deduction",
        "zorgverzekering", "eigen", "risico", "premie", "insurance", "premium",
        "hypotheek", "rente", "mortgage", "interest",
        "pensioen", "pension", "aow",
        "abonnement", "opzegtermijn", "contract", "boete", "subscription",
    ]

    /// A query built without asking the model — the fallback when the planning
    /// call fails, and the floor the model result is checked against.
    public static func fallbackQuery(
        question: String,
        screenText: String = "",
        visualReading: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let cleaned = stripPlaceholders(question)
        var parts: [String] = []
        if !cleaned.isEmpty { parts.append(cleaned) }

        // Only borrow from the screen when the question cannot stand alone.
        // A specific question does not need the whole contract stapled to it.
        if !carriesItsOwnTopic(cleaned) {
            let anchors = topicAnchors(in: "\(visualReading)\n\(screenText)")
            if !anchors.isEmpty { parts.append(anchors.joined(separator: " ")) }
        }

        if !mentionsPlace(cleaned) { parts.append("Nederland") }

        // Rates and thresholds are yearly. Without a year the engine happily
        // returns a page from four years ago.
        let year = calendar.component(.year, from: now)
        if !cleaned.contains(String(year)) { parts.append(String(year)) }

        return TextNormalization.collapseWhitespace(parts.joined(separator: " "))
    }

    /// Whether a question would mean anything to a search engine on its own.
    static func carriesItsOwnTopic(_ question: String) -> Bool {
        let words = MemoryStore.terms(in: question)
        guard words.count >= 4 else { return false }
        return !words.isDisjoint(with: domainTerms)
    }

    static func mentionsPlace(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["nederland", "netherlands", "dutch", "holland", " nl"]
            .contains { lowered.contains($0) }
    }

    /// The handful of words from a screen that say what it is about.
    ///
    /// Domain words first, then capitalised words — a provider or agency name
    /// is usually the single most useful term in the query.
    static func topicAnchors(in screen: String, limit: Int = 6) -> [String] {
        let words = screen.split { !($0.isLetter || $0.isNumber) }.map(String.init)

        var domain: [String] = []
        var names: [String] = []
        var seen = Set<String>()

        for word in words {
            let lowered = word.lowercased()
            guard lowered.count > 2, !seen.contains(lowered) else { continue }

            if domainTerms.contains(lowered) {
                seen.insert(lowered)
                domain.append(lowered)
            } else if let first = word.first, first.isUppercase,
                      word.dropFirst().contains(where: { $0.isLowercase }) {
                seen.insert(lowered)
                names.append(word)
            }
        }
        // Names lead: "Budget Thuis" narrows a query far harder than "tarief".
        return Array((names.prefix(2) + domain).prefix(limit))
    }

    static func stripPlaceholders(_ text: String) -> String {
        var value = text
        if let regex = Redactor.placeholderPattern {
            value = regex.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: " "
            )
        }
        return TextNormalization.collapseWhitespace(value)
    }

    /// Whether a model-written query is good enough to prefer over the
    /// fallback. A model asked for a query will occasionally return a
    /// sentence, an apology, or the word "search".
    static func isAcceptable(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 300 else { return false }
        guard !trimmed.contains("[[R") else { return false }
        return MemoryStore.terms(in: trimmed).count >= 2
    }
}
