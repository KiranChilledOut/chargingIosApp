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
