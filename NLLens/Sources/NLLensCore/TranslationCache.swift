import Foundation

public struct CacheEntry: Codable, Sendable, Equatable, Identifiable {
    /// Stable hash of the normalized source text.
    public var k: String
    /// Repaired Dutch.
    public var nl: String
    /// English.
    public var en: String
    /// Unix seconds, for cache inspection and pruning.
    public var t: Double
    /// A correction the user made by hand. Never overwritten by a model result.
    public var pinned: Bool

    public var id: String { k }

    public init(k: String, nl: String, en: String, t: Double = Date().timeIntervalSince1970, pinned: Bool = false) {
        self.k = k
        self.nl = nl
        self.en = en
        self.t = t
        self.pinned = pinned
    }
}

/// Persistent translation memory, backed by an append-only JSONL file.
///
/// This is what makes a cloud round trip feel instant on the screens you see
/// daily, and it is the entire offline story. It is also the place a wrong
/// translation gets fixed once instead of being re-read wrong forever.
///
/// JSONL rather than SQLite because an App Intent process is short-lived: an
/// append is one `write`, startup is one sequential read, and there is no
/// schema migration to get wrong. At personal-use scale (thousands of entries,
/// not millions) this is comfortably fast enough.
public actor TranslationCache {

    private var entries: [String: CacheEntry] = [:]
    private var pending: [CacheEntry] = []
    /// Lines physically in the file, including superseded ones.
    private var lineCount: Int = 0
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public var count: Int { entries.count }
    public var pendingCount: Int { pending.count }
    public var storedLineCount: Int { lineCount }

    // MARK: - Loading

    /// Reads the log into memory. Later lines win, which is how corrections
    /// and re-translations supersede earlier entries.
    ///
    /// A corrupt line is skipped rather than fatal: a half-written line from a
    /// process killed mid-append must not destroy the whole cache.
    public func load() throws {
        entries.removeAll()
        pending.removeAll()
        lineCount = 0

        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            lineCount += 1
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(CacheEntry.self, from: data) else {
                continue
            }
            // A pinned correction is never displaced by a later model result.
            if let existing = entries[entry.k], existing.pinned, !entry.pinned {
                continue
            }
            entries[entry.k] = entry
        }
    }

    // MARK: - Reading

    public func lookup(_ sourceText: String) -> CacheEntry? {
        entries[TextNormalization.cacheKey(sourceText)]
    }

    /// Splits blocks into those already known and those needing the network.
    public func partition(
        blocks: [TextBlock]
    ) -> (hits: [Int: CacheEntry], misses: [TextBlock]) {
        var hits: [Int: CacheEntry] = [:]
        var misses: [TextBlock] = []

        for block in blocks {
            if let entry = lookup(block.text) {
                hits[block.id] = entry
            } else {
                misses.append(block)
            }
        }
        return (hits, misses)
    }

    public func allEntries() -> [CacheEntry] {
        entries.values.sorted { $0.t > $1.t }
    }

    // MARK: - Writing

    /// Queues an entry. Call `flush()` to persist.
    public func store(nl: String, en: String, pinned: Bool = false) {
        let key = TextNormalization.cacheKey(nl)

        if let existing = entries[key], existing.pinned, !pinned {
            return  // a hand correction outranks a model result
        }
        let entry = CacheEntry(k: key, nl: nl, en: en, pinned: pinned)
        entries[key] = entry
        pending.append(entry)
    }

    /// Records a hand correction, which from now on always wins.
    public func pin(nl: String, en: String) {
        store(nl: nl, en: en, pinned: true)
    }

    public func store(blocks: [TranslatedBlock]) {
        for block in blocks where !block.fromCache {
            store(nl: block.sourceText, en: block.translatedText)
        }
    }

    /// Appends queued entries, then compacts if the log has grown wasteful.
    @discardableResult
    public func flush() throws -> Int {
        guard !pending.isEmpty else { return 0 }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var payload = Data()
        for entry in pending {
            payload.append(try encoder.encode(entry))
            payload.append(0x0A)  // \n
        }

        try appendToFile(payload)
        let written = pending.count
        lineCount += written
        pending.removeAll()

        // Rewriting once the log is mostly superseded entries keeps startup
        // reads bounded no matter how long the app has been in use.
        if lineCount > max(64, entries.count * 2) {
            try compact()
        }
        return written
    }

    /// Rewrites the file with only the current entries.
    public func compact() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var payload = Data()
        for entry in entries.values.sorted(by: { $0.t < $1.t }) {
            payload.append(try encoder.encode(entry))
            payload.append(0x0A)
        }

        try ensureDirectoryExists()
        // `.atomic` writes to a neighbouring temp file and renames it into
        // place, so an interrupted compaction cannot leave a truncated cache.
        // Done via `Data.write` rather than `replaceItemAt`, which is not
        // dependable on swift-corelibs-foundation.
        try payload.write(to: fileURL, options: .atomic)
        lineCount = entries.count
    }

    public func removeAll() throws {
        entries.removeAll()
        pending.removeAll()
        lineCount = 0
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    // MARK: - File plumbing

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
    }

    private func appendToFile(_ data: Data) throws {
        try ensureDirectoryExists()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
