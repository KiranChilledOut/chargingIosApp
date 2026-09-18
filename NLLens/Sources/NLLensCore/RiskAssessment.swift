import Foundation

/// Whether a captured screen is trying to defraud the person reading it.
public struct RiskAssessment: Codable, Hashable, Sendable {

    public enum Level: String, Codable, Sendable, CaseIterable {
        case fine, caution, danger

        /// Maps whatever word the model reached for onto the three levels.
        ///
        /// Unknown words resolve to `caution` rather than `fine`: if the model
        /// said something this code does not recognise, that is not evidence
        /// the screen is safe.
        static func parse(_ raw: String?) -> Level {
            switch raw?.lowercased().trimmingCharacters(in: .whitespaces) {
            case "fine", "safe", "ok", "okay", "none", "low", "clean", "legitimate":
                return .fine
            case "danger", "high", "scam", "phishing", "fraud", "critical", "severe":
                return .danger
            case "caution", "medium", "moderate", "suspicious", "warning", "unclear":
                return .caution
            case .none:
                return .caution
            default:
                return .caution
            }
        }
    }

    public var level: Level
    public var headline: String
    /// What specifically looks wrong. Empty on an ordinary screen.
    public var signals: [String]
    public var advice: String

    public init(
        level: Level,
        headline: String,
        signals: [String] = [],
        advice: String = ""
    ) {
        self.level = level
        self.headline = headline
        self.signals = signals
        self.advice = advice
    }

    /// True when there is something worth showing the user. An ordinary screen
    /// should stay silent rather than reassure — a badge on every screen is a
    /// badge nobody reads, and the one that matters disappears into the noise.
    public var isWorthSurfacing: Bool {
        level != .fine
    }

    enum CodingKeys: String, CodingKey {
        case level, headline, signals, advice
        // Alternate spellings seen in the wild.
        case risk, summary, reasons, recommendation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        level = Level.parse(Lenient.string(in: container, forKeys: [.level, .risk]))
        headline = Lenient.string(in: container, forKeys: [.headline, .summary]) ?? ""

        let signals = Lenient.stringList(in: container, forKey: .signals)
        self.signals = signals.isEmpty
            ? Lenient.stringList(in: container, forKey: .reasons)
            : signals

        advice = Lenient.string(in: container, forKeys: [.advice, .recommendation]) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encode(headline, forKey: .headline)
        try container.encode(signals, forKey: .signals)
        try container.encode(advice, forKey: .advice)
    }
}
