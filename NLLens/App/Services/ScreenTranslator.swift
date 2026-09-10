import Foundation
import UIKit
import NLLensCore

/// The one path from screenshot to rendered overlay.
///
/// Shared by the App Intent and the in-app picker so the two cannot drift —
/// a difference between "what Back Tap does" and "what the app does" would be
/// invisible until it mattered.
public enum ScreenTranslator {

    public struct Result {
        public let original: UIImage
        public let rendered: UIImage
        public let outcome: TranslationOutcome
    }

    public struct MultiResult {
        public let firstOriginal: UIImage?
        public let firstRendered: UIImage?
        public let document: StitchedDocument
        public let outcome: TranslationOutcome
    }

    public enum Failure: Error, LocalizedError {
        case undecodableImage
        case noTextFound

        public var errorDescription: String? {
            switch self {
            case .undecodableImage:
                return "That image could not be read."
            case .noTextFound:
                return "No text was recognised on that screen."
            }
        }
    }

    /// Recognizes, translates, renders and records a screenshot.
    public static func translate(
        image: UIImage,
        environment: AppEnvironment = .shared
    ) async throws -> Result {
        guard let cgImage = image.cgImage else { throw Failure.undecodableImage }

        let blocks = try VisionOCR.recognize(cgImage: cgImage)
        guard !blocks.isEmpty else { throw Failure.noTextFound }

        let pipeline = await environment.pipeline()
        let outcome = try await pipeline.translate(blocks: blocks)
        let rendered = OverlayRenderer.render(image: image, blocks: outcome.blocks)

        LastResultStore.store(
            original: image, rendered: rendered, outcome: outcome
        )
        return Result(original: image, rendered: rendered, outcome: outcome)
    }

    /// Recognizes and translates several captures taken while scrolling, and
    /// joins them into one continuous document.
    ///
    /// Each capture is translated on its own rather than as one giant request:
    /// the overlap between consecutive captures then arrives as cache hits, so
    /// the lines a reader deliberately re-captured to avoid missing cost
    /// nothing the second time.
    public static func translateMany(
        images: [UIImage],
        environment: AppEnvironment = .shared,
        onProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> MultiResult {
        guard !images.isEmpty else { throw Failure.noTextFound }

        let pipeline = await environment.pipeline()
        var screens: [[TranslatedBlock]] = []
        var firstRendered: UIImage?
        var firstOriginal: UIImage?
        var totalRedacted = 0
        var cacheHits = 0

        for (index, image) in images.enumerated() {
            onProgress(index, images.count)

            guard let cgImage = image.cgImage else { continue }
            let blocks = try VisionOCR.recognize(cgImage: cgImage)
            guard !blocks.isEmpty else { continue }

            let outcome = try await pipeline.translate(blocks: blocks)
            screens.append(outcome.blocks)
            totalRedacted += outcome.redactedCount
            cacheHits += outcome.cacheHits

            if firstRendered == nil {
                firstRendered = OverlayRenderer.render(image: image, blocks: outcome.blocks)
                firstOriginal = image
            }
        }
        onProgress(images.count, images.count)

        guard !screens.isEmpty else { throw Failure.noTextFound }
        let document = ScreenStitching.merge(screens)

        let outcome = TranslationOutcome(
            blocks: document.blocks,
            cacheHits: cacheHits,
            redactedCount: totalRedacted
        )
        if let firstRendered, let firstOriginal {
            LastResultStore.store(
                original: firstOriginal, rendered: firstRendered,
                outcome: outcome, screenCount: document.screenCount
            )
        }

        return MultiResult(
            firstOriginal: firstOriginal,
            firstRendered: firstRendered,
            document: document,
            outcome: outcome
        )
    }

    /// Recognizes only, for the on-device fallback path which translates in a
    /// SwiftUI context rather than here.
    public static func recognize(image: UIImage) throws -> [TextBlock] {
        guard let cgImage = image.cgImage else { throw Failure.undecodableImage }
        let blocks = try VisionOCR.recognize(cgImage: cgImage)
        guard !blocks.isEmpty else { throw Failure.noTextFound }
        return BlockGrouping.group(blocks)
    }
}
