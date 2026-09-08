import Foundation
import Vision
import CoreGraphics
import NLLensCore

/// Wraps Vision's text recognizer for Dutch screenshots.
///
/// Vision does not support Dutch. It does support the Latin script, and the
/// two are not the same limitation: the glyph recognizer reads Dutch letters
/// correctly, it is the *language correction* pass that mangles Dutch words
/// into English-looking ones. Turning that pass off yields accurate characters
/// with no lexical smoothing, and the language model downstream repairs
/// whatever noise remains using the context of the whole screen.
public enum VisionOCR {

    public enum Failure: Error, LocalizedError {
        case noImage
        case recognitionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noImage:
                return "Could not read that screenshot."
            case .recognitionFailed(let message):
                return "Text recognition failed: \(message)"
            }
        }
    }

    /// Minimum confidence to keep a recognized line. Vision emits very
    /// low-confidence candidates for icons and texture; below this they are
    /// noise that costs tokens and confuses the grouping pass.
    public static let minimumConfidence: Float = 0.3

    public static func recognize(cgImage: CGImage) throws -> [TextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate

        // The two settings that make an unsupported source language work.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        // Screens are dense with small text; the default minimum drops it.
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.recognitionFailed(error.localizedDescription)
        }

        guard let observations = request.results else { return [] }

        var blocks: [TextBlock] = []
        blocks.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minimumConfidence else { continue }

            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            blocks.append(TextBlock(
                id: blocks.count,
                text: text,
                box: normalizedTopLeftBox(from: observation.boundingBox),
                confidence: Double(candidate.confidence)
            ))
        }
        return blocks
    }

    /// Converts Vision's bottom-left-origin normalized rect to the top-left
    /// convention the rest of the app uses. The arithmetic lives in
    /// `BoundingBox.fromVisionNormalized`, where it is unit-tested.
    static func normalizedTopLeftBox(from rect: CGRect) -> BoundingBox {
        BoundingBox.fromVisionNormalized(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}
