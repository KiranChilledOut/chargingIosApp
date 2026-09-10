import Foundation
import UIKit
import NLLensCore

/// Keeps the most recent translation so opening the app shows the full-size
/// overlay, with the pair list you can correct entries from.
///
/// Written to disk rather than held in memory because the App Intent process
/// may be torn down the moment its snippet is displayed.
public enum LastResultStore {

    public struct Snapshot {
        public var renderedImage: UIImage?
        public var originalImage: UIImage?
        public var pairs: [TranslatedBlock]
        public var createdAt: Date
        /// How many captures were stitched together. Above one, the boxes no
        /// longer share a coordinate space, so the result is for reading
        /// rather than for drawing an overlay.
        public var screenCount: Int = 1

        public var isMultiScreen: Bool { screenCount > 1 }
    }

    private struct Persisted: Codable {
        var pairs: [TranslatedBlock]
        var createdAt: Date
        /// Optional so snapshots written by an earlier build still decode.
        var screenCount: Int?
    }

    private static var directory: URL {
        AppEnvironment.containerURL()
            .appendingPathComponent("NLLens", isDirectory: true)
    }

    private static var renderedURL: URL { directory.appendingPathComponent("last-rendered.jpg") }
    private static var originalURL: URL { directory.appendingPathComponent("last-original.jpg") }
    private static var metadataURL: URL { directory.appendingPathComponent("last-result.json") }

    public static func store(
        original: UIImage,
        rendered: UIImage,
        outcome: TranslationOutcome,
        screenCount: Int = 1
    ) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            if let data = rendered.jpegData(compressionQuality: 0.85) {
                try data.write(to: renderedURL, options: .atomic)
            }
            if let data = original.jpegData(compressionQuality: 0.7) {
                try data.write(to: originalURL, options: .atomic)
            }
            let payload = Persisted(
                pairs: outcome.blocks, createdAt: Date(), screenCount: screenCount
            )
            try JSONEncoder().encode(payload).write(to: metadataURL, options: .atomic)
        } catch {
            // Losing the snapshot costs the in-app review view, not the
            // translation the user just received.
            NSLog("NLLens: could not persist last result: \(error.localizedDescription)")
        }
    }

    public static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: metadataURL),
              let payload = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return nil }

        return Snapshot(
            renderedImage: (try? Data(contentsOf: renderedURL)).flatMap(UIImage.init(data:)),
            originalImage: (try? Data(contentsOf: originalURL)).flatMap(UIImage.init(data:)),
            pairs: payload.pairs,
            createdAt: payload.createdAt,
            screenCount: payload.screenCount ?? 1
        )
    }

    public static func clear() {
        for url in [renderedURL, originalURL, metadataURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
