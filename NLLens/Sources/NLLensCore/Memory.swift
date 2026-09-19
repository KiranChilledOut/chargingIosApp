import Foundation

/// Something worth remembering about the person between screens.
///
/// Keyed rather than appended blindly: a tariff learned in March and a tariff
/// learned in September are the same fact with a new value, and keeping both
/// would have the model hedging between two numbers it cannot choose between.
public struct MemoryFact: Codable, Sendable, Equatable, Identifiable {
    /// Stable slug — `energy-tariff`, `housing`, `employer`. New values for the
    /// same key supersede rather than accumulate.
    public var key: String
    /// How to refer to it in a prompt: "Electricity tariff".
    public var label: String
    public var value: String
    /// Where it was learned, so an answer can say so.
    public var source: String
    public var recordedAt: Date

    public var id: String { key }

    public init(
        key: String,
        label: String,
        value: String,
        source: String = "",
        recordedAt: Date = Date()
    ) {
        self.key = MemoryFact.normalizeKey(key)
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.recordedAt = recordedAt
    }

    public static func normalizeKey(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    public var line: String {
        label.isEmpty ? value : "\(label): \(value)"
    }

    /// Whether this is safe and sensible to keep.
    ///
    /// Facts are extracted from text that has already been through the
    /// redactor, so an IBAN arrives as `[[R1]]` — a token that means nothing
    /// later and would be quoted back as though it were a value. Anything
    /// carrying one is dropped rather than stored.
    public var isStorable: Bool {
        guard !key.isEmpty, !value.isEmpty else { return false }
        guard value.count <= 240 else { return false }
        guard !value.contains("[[R"), !label.contains("[[R") else { return false }
        // A model asked for facts will sometimes answer that it has none.
        let empties: Set<String> = ["unknown", "none", "n/a", "not stated", "null"]
        return !empties.contains(value.lowercased())
    }
}

/// What the app knows about the person, carried between screens.
///
/// Without this every conversation restarts from nothing: the screen is in
/// front of the model, but the tariff they were comparing last week, the fact
/// that they rent, and the provider they are leaving are not — so the model
/// asks again, or worse, answers generically. Continuity is the whole point of
/// a translator that also advises.
///
/// Append-only JSONL, matching `TranslationCache`: one `write` to record, one
/// sequential read at startup, and a half-written line from a process killed
/// mid-append costs one fact rather than the file.
public actor MemoryStore {

    private var facts: [String: MemoryFact] = [:]
    private let fileURL: URL
    private let fileManager: FileManager
    /// Facts kept. Beyond this the oldest go: a prompt cannot carry hundreds,
    /// and stale facts are worse than absent ones.
    private let limit: Int

    public init(fileURL: URL, limit: Int = 120, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.limit = limit
        self.fileManager = fileManager
    }

    public var count: Int { facts.count }

    public var all: [MemoryFact] {
        facts.values.sorted { $0.recordedAt > $1.recordedAt }
    }

    // MARK: - Loading

    public func load() throws {
        facts.removeAll()
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let fact = try? decoder.decode(MemoryFact.self, from: data)
            else { continue }
            // Later lines win, which is how a changed tariff supersedes the
            // one recorded before it.
            facts[fact.key] = fact
        }
        prune()
    }

    // MARK: - Recording

    /// Records facts, newest value winning per key.
    ///
    /// Returns the ones actually kept, so a caller can say what was learned
    /// rather than claiming to have learned everything it was handed.
    @discardableResult
    public func record(_ incoming: [MemoryFact]) throws -> [MemoryFact] {
        let storable = incoming.filter(\.isStorable)
        guard !storable.isEmpty else { return [] }

        var kept: [MemoryFact] = []
        for fact in storable {
            // An identical value re-learned is not news; keep the original
            // timestamp so "recently learned" stays meaningful.
            if let existing = facts[fact.key], existing.value == fact.value { continue }
            facts[fact.key] = fact
            kept.append(fact)
        }
        guard !kept.isEmpty else { return [] }

        prune()
        try append(kept)
        return kept
    }

    public func forget(key: String) throws {
        let normalized = MemoryFact.normalizeKey(key)
        guard facts.removeValue(forKey: normalized) != nil else { return }
        try rewrite()
    }

    public func forgetAll() throws {
        facts.removeAll()
        try rewrite()
    }

    // MARK: - Recall

    /// The facts worth spending prompt space on for this question.
    ///
    /// Scored on shared words with the question and the screen, then on
    /// recency. Everything is never the answer: a prompt carrying forty facts
    /// buries the two that matter, and the model starts answering about the
    /// wrong one.
    public func relevant(to context: String, limit: Int = 8) -> [MemoryFact] {
        let wanted = MemoryStore.terms(in: context)
        guard !wanted.isEmpty else { return Array(all.prefix(limit)) }

        let now = Date()
        let scored = facts.values.map { fact -> (MemoryFact, Double) in
            let text = MemoryStore.terms(in: "\(fact.key) \(fact.label) \(fact.value)")
            let overlap = Double(text.intersection(wanted).count)
            // Days, so a fact learned today edges out an equally relevant one
            // from months ago without ever outweighing a real term match.
            let age = now.timeIntervalSince(fact.recordedAt) / 86_400
            return (fact, overlap * 10 - min(age, 180) / 180)
        }

        return scored
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.recordedAt > rhs.0.recordedAt : lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    /// The block handed to the model.
    public func grounding(for context: String, limit: Int = 8) -> String {
        let picked = relevant(to: context, limit: limit)
        guard !picked.isEmpty else { return "" }

        return ([
            "What you already know about this person, from screens they showed you "
                + "earlier. Use it rather than asking again, and say when an answer "
                + "rests on it so they can correct you if it has changed.",
        ] + picked.map { "- \($0.line)" }).joined(separator: "\n")
    }

    static func terms(in text: String) -> Set<String> {
        let pieces = text.lowercased().split { !($0.isLetter || $0.isNumber) }
        // Two-letter words carry no topic and match everything.
        return Set(pieces.filter { $0.count > 2 }.map(String.init))
    }

    // MARK: - Storage

    private func prune() {
        guard facts.count > limit else { return }
        let doomed = facts.values
            .sorted { $0.recordedAt < $1.recordedAt }
            .prefix(facts.count - limit)
        for fact in doomed { facts.removeValue(forKey: fact.key) }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Paired with the decoder's strategy above. Mismatched strategies are
        // how a store writes happily and reads back empty.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func append(_ newFacts: [MemoryFact]) throws {
        let encoder = encoder()
        var payload = Data()
        for fact in newFacts {
            payload.append(try encoder.encode(fact))
            payload.append(0x0A)
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard fileManager.fileExists(atPath: fileURL.path) else {
            try payload.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    /// Rewrites the file from memory, for the paths that remove rather than add.
    private func rewrite() throws {
        let encoder = encoder()
        var payload = Data()
        for fact in all.reversed() {
            payload.append(try encoder.encode(fact))
            payload.append(0x0A)
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic rather than replaceItemAt, which is unreliable on
        // corelibs-foundation.
        try payload.write(to: fileURL, options: .atomic)
    }
}
