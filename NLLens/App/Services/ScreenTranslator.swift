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

    /// Recognizes only, for the on-device fallback path which translates in a
    /// SwiftUI context rather than here.
    public static func recognize(image: UIImage) throws -> [TextBlock] {
        guard let cgImage = image.cgImage else { throw Failure.undecodableImage }
        let blocks = try VisionOCR.recognize(cgImage: cgImage)
        guard !blocks.isEmpty else { throw Failure.noTextFound }
        return BlockGrouping.group(blocks)
    }
}
