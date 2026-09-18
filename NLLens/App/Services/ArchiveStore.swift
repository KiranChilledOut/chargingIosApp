import Foundation
import UIKit
import NLLensCore

/// One captured screen, kept.
public struct ArchiveEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    /// The screen in English. This is what search runs against — the whole
    /// point is finding a Dutch document by what it said in English.
    public var englishText: String
    public var dutchText: String
    public var conversation: ScreenConversation?
    public var hasImage: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        englishText: String,
        dutchText: String,
        conversation: ScreenConversation? = nil,
        hasImage: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.englishText = englishText
        self.dutchText = dutchText
        self.conversation = conversation
        self.hasImage = hasImage
    }

    public var questionCount: Int {
        conversation?.messages.filter { $0.role == .user }.count ?? 0
    }
}

/// A searchable English record of your Dutch life.
///
/// The feature nothing else offers: months later, "when did I get that letter
/// about huurtoeslag?" is answerable, in English, from a pile of documents you
/// could not read at the time.
public enum ArchiveStore {

    /// Oldest entries are pruned beyond this. Images dominate the footprint,
    /// and a personal archive has no business growing without bound.
    public static let maximumEntries = 300

    private static var directory: URL {
        AppEnvironment.containerURL()
            .appendingPathComponent("NLLens/Archive", isDirectory: true)
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    private static func imageURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    // MARK: - Reading

    public static func all() -> [ArchiveEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? decoder.decode([ArchiveEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Paired with `encoder` below. The two strategies must match, or the
    /// archive writes fine and reads back as empty.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Case- and accent-insensitive search across the English, the Dutch and
    /// the conversation — you may remember what you *asked* rather than what
    /// the screen said.
    public static func search(_ query: String, in entries: [ArchiveEntry]) -> [ArchiveEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }

        return entries.filter { entry in
            let haystack = [
                entry.title, entry.englishText, entry.dutchText,
                entry.conversation?.messages.map(\.text).joined(separator: " ") ?? "",
            ].joined(separator: " ")

            return haystack.range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    public static func image(for entry: ArchiveEntry) -> UIImage? {
        guard entry.hasImage,
              let data = try? Data(contentsOf: imageURL(for: entry.id)) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Writing

    @discardableResult
    public static func save(
        snapshot: LastResultStore.Snapshot,
        conversation: ScreenConversation? = nil
    ) -> ArchiveEntry? {
        guard !snapshot.pairs.isEmpty else { return nil }

        var entry = ArchiveEntry(
            title: ArchiveTitle.derive(from: snapshot.pairs),
            englishText: snapshot.pairs.map(\.translatedText).joined(separator: "\n"),
            dutchText: snapshot.pairs.map(\.sourceText).joined(separator: "\n"),
            conversation: conversation
        )

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            if let image = snapshot.renderedImage,
               let data = image.jpegData(compressionQuality: 0.7) {
                try data.write(to: imageURL(for: entry.id), options: .atomic)
                entry.hasImage = true
            }
            var entries = all()
            entries.insert(entry, at: 0)
            try write(prune(entries))
            return entry
        } catch {
            NSLog("NLLens: could not archive screen: \(error.localizedDescription)")
            return nil
        }
    }

    /// Attaches a conversation to an entry that already exists.
    public static func update(id: UUID, conversation: ScreenConversation) {
        var entries = all()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].conversation = conversation
        try? write(entries)
    }

    public static func delete(_ entry: ArchiveEntry) {
        try? FileManager.default.removeItem(at: imageURL(for: entry.id))
        try? write(all().filter { $0.id != entry.id })
    }

    public static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Plumbing

    private static func write(_ entries: [ArchiveEntry]) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    /// Drops the oldest beyond the cap, and their images with them — an
    /// orphaned jpeg would otherwise outlive its entry forever.
    private static func prune(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        guard entries.count > maximumEntries else { return entries }
        let kept = Array(entries.prefix(maximumEntries))
        for dropped in entries.dropFirst(maximumEntries) {
            try? FileManager.default.removeItem(at: imageURL(for: dropped.id))
        }
        return kept
    }
}
