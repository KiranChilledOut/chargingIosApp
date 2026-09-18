import Foundation

/// A rectangle in normalized image coordinates.
///
/// Origin is **top-left**, axes run 0...1. Vision reports bottom-left origin,
/// so `VisionOCR` flips the y-axis before constructing these. Keeping one
/// convention here means the layout and rendering code never has to ask.
public struct BoundingBox: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midY: Double { y + height / 2 }
    public var maxY: Double { y + height }
    public var maxX: Double { x + width }

    /// Union of two boxes, used when merging OCR lines into a paragraph.
    public func union(_ other: BoundingBox) -> BoundingBox {
        let minX = Swift.min(x, other.x)
        let minY = Swift.min(y, other.y)
        let maxX = Swift.max(self.maxX, other.maxX)
        let maxY = Swift.max(self.maxY, other.maxY)
        return BoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Vertical gap between this box and one below it, negative if they overlap.
    public func verticalGap(to other: BoundingBox) -> Double {
        other.y - maxY
    }

    /// Builds a box from Vision's normalized, **bottom-left origin** rect.
    ///
    /// Vision measures y upward from the bottom; everything else here measures
    /// it downward from the top. Getting this backwards mirrors every label
    /// down the screen, which reads as a layout bug rather than a coordinate
    /// one — so the conversion lives here, with tests, instead of inline at
    /// the call site.
    public static func fromVisionNormalized(
        x: Double, y: Double, width: Double, height: Double
    ) -> BoundingBox {
        BoundingBox(x: x, y: 1.0 - (y + height), width: width, height: height)
    }
}

/// One run of text recognized on screen, before translation.
public struct TextBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    /// Raw recognizer output. May contain OCR noise; the LLM repairs it.
    public var text: String
    public var box: BoundingBox
    public var confidence: Double

    public init(id: Int, text: String, box: BoundingBox, confidence: Double = 1.0) {
        self.id = id
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// A block after translation, carrying both the repaired source and the English.
public struct TranslatedBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    /// OCR-repaired Dutch. Shown in the "compare" view and stored in the cache.
    public var sourceText: String
    public var translatedText: String
    public var box: BoundingBox
    /// True when this came from the local cache rather than the network.
    public var fromCache: Bool

    public init(
        id: Int,
        sourceText: String,
        translatedText: String,
        box: BoundingBox,
        fromCache: Bool = false
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.box = box
        self.fromCache = fromCache
    }
}

/// What the model returns for one block. Kept separate from `TranslatedBlock`
/// because the wire format has no geometry — we re-attach boxes by id.
public struct TranslationUnit: Codable, Hashable, Sendable {
    public var id: Int
    /// Repaired source text. Key `nl` on the wire to keep the prompt terse.
    public var nl: String
    public var en: String

    public init(id: Int, nl: String, en: String) {
        self.id = id
        self.nl = nl
        self.en = en
    }
}

/// Result of the "explain this screen" path, which uses a vision model.
public struct ScreenExplanation: Codable, Hashable, Sendable {
    /// One-line answer to "what is this screen".
    public var summary: String
    /// What the user is being asked to do, in order.
    public var actions: [String]
    /// Things worth noticing: pre-ticked boxes, costs, deadlines, errors.
    public var warnings: [String]

    public init(summary: String, actions: [String] = [], warnings: [String] = []) {
        self.summary = summary
        self.actions = actions
        self.warnings = warnings
    }

    /// Decoded leniently, because a schema is a request rather than a
    /// guarantee.
    ///
    /// Vision models drift from the shape they were asked for far more than
    /// text models do — a lone action arrives as a bare string instead of a
    /// one-element array, a list arrives as objects with a `text` key, an
    /// empty section is omitted rather than sent as `[]`. Any of those would
    /// throw under synthesized decoding, and the user would get an error for
    /// a reply that was perfectly usable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        summary = Lenient.string(
            in: container, forKeys: [.summary, .title, .explanation]
        ) ?? ""
        actions = Lenient.stringList(in: container, forKey: .actions)
        warnings = Lenient.stringList(in: container, forKey: .warnings)
    }

    enum CodingKeys: String, CodingKey {
        case summary, actions, warnings
        // Alternate spellings seen in the wild. Read on the way in, never
        // written on the way out — which is why `encode(to:)` is explicit:
        // their presence stops Swift synthesizing one.
        case title, explanation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(actions, forKey: .actions)
        try container.encode(warnings, forKey: .warnings)
    }

    /// True when the model returned nothing usable, so the caller can say so
    /// rather than presenting an empty card.
    public var isEmpty: Bool {
        summary.isEmpty && actions.isEmpty && warnings.isEmpty
    }
}

/// Direction for the compose/typing feature.
public enum Register: String, Codable, Sendable, CaseIterable {
    case formal
    case casual
    case business

    /// Guidance appended to the compose prompt. The u/je distinction is the
    /// mistake a non-speaker reliably makes, so it is called out explicitly.
    public var guidance: String {
        switch self {
        case .formal:
            return "Formal Dutch. Use 'u' (never 'je'/'jij'). Suitable for government forms, banks, insurers, landlords."
        case .casual:
            return "Casual spoken Dutch. Use 'je'/'jij'. Suitable for friends, colleagues you know well, informal chat."
        case .business:
            return "Professional but not stiff. Use 'u' unless the context clearly implies a first-name relationship. Suitable for customer service and workplace email."
        }
    }
}

public struct ComposeResult: Codable, Hashable, Sendable {
    public var dutch: String
    /// Short notes on choices a learner would want flagged (u vs je, idiom).
    public var notes: [String]

    public init(dutch: String, notes: [String] = []) {
        self.dutch = dutch
        self.notes = notes
    }
}
