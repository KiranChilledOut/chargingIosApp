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

    /// Minimum confidence to keep a recognized line.
    ///
    /// Zero on purpose. Filtering here contradicts the rest of the design:
    /// language correction is off because it mangles Dutch, which means the
    /// recognizer is reading Dutch with no lexicon behind it and reports
    /// systematically low confidence for text it got *right*. A 0.3 floor
    /// silently dropped correct Dutch before the model ever saw it.
    ///
    /// The model repairs noise; it cannot recover a line that never arrived.
    /// A junk line costs a few tokens and is obvious on screen. A missing
    /// sentence is silent, and the reader cannot tell it from one that was
    /// never there. So the bias runs hard toward keeping everything.
    public static let minimumConfidence: Float = 0

    public static func recognize(cgImage: CGImage) throws -> [TextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate

        // The two settings that make an unsupported source language work.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        // Vision defaults to 1/32 of the image height, which discards the
        // fine print — terms, disclaimers, the line about what renews — that
        // is exactly what someone who cannot read Dutch most needs.
        request.minimumTextHeight = 0.005

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
            if minimumConfidence > 0, candidate.confidence < minimumConfidence {
                continue
            }

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
