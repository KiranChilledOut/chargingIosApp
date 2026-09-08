import Foundation
import UIKit
import NLLensCore

/// Draws the English back onto the screenshot, in the place the Dutch was.
///
/// The alternative — a list of translated strings — loses the thing that makes
/// a screen readable, which is knowing which label belongs to which control.
/// So each translated run is painted over its original box, on a background
/// sampled from the pixels underneath so it reads as part of the screen rather
/// than a sticky note.
public enum OverlayRenderer {

    public struct Style: Sendable {
        /// Cap on drawn text size, in points at image scale.
        public var maximumFontScale: Double
        public var minimumFontSize: Double
        public var cornerRadius: Double
        /// Padding inside each replaced box.
        public var inset: Double

        public init(
            maximumFontScale: Double = 0.78,
            minimumFontSize: Double = 9,
            cornerRadius: Double = 3,
            inset: Double = 1.5
        ) {
            self.maximumFontScale = maximumFontScale
            self.minimumFontSize = minimumFontSize
            self.cornerRadius = cornerRadius
            self.inset = inset
        }

        public static let `default` = Style()
    }

    public static func render(
        image: UIImage,
        blocks: [TranslatedBlock],
        style: Style = .default
    ) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))

            for block in blocks {
                // Nothing changed, so leave the original pixels alone. This is
                // the common case for numbers, prices and brand names.
                guard block.translatedText != block.sourceText else { continue }

                let rect = CGRect(
                    x: block.box.x * size.width,
                    y: block.box.y * size.height,
                    width: block.box.width * size.width,
                    height: block.box.height * size.height
                ).insetBy(dx: -style.inset, dy: -style.inset)

                guard rect.width > 2, rect.height > 2 else { continue }

                let background = averageColor(of: image, in: rect) ?? .systemBackground
                let foreground = contrastingTextColor(for: background)

                let path = UIBezierPath(
                    roundedRect: rect, cornerRadius: style.cornerRadius
                )
                background.setFill()
                path.fill()

                draw(
                    text: block.translatedText,
                    in: rect.insetBy(dx: style.inset, dy: 0),
                    color: foreground,
                    style: style,
                    context: context.cgContext
                )
            }
        }
    }

    // MARK: - Text

    private static func draw(
        text: String,
        in rect: CGRect,
        color: UIColor,
        style: Style,
        context: CGContext
    ) {
        let maxFontSize = max(style.minimumFontSize, rect.height * style.maximumFontScale)
        let fontSize = LayoutFitting.fittedFontSize(
            text: text,
            boxWidth: Double(rect.width),
            boxHeight: Double(rect.height),
            maxFontSize: Double(maxFontSize),
            minFontSize: style.minimumFontSize
        )

        let font = UIFont.systemFont(ofSize: CGFloat(fontSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let bounding = attributed.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        // Centre vertically in the original box so the replacement sits on the
        // same baseline the eye already expects.
        let y = rect.midY - bounding.height / 2
        attributed.draw(with: CGRect(
            x: rect.minX, y: max(rect.minY, y),
            width: rect.width, height: min(rect.height, bounding.height)
        ), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    // MARK: - Colour sampling

    /// Mean colour of a region, used as the fill that hides the Dutch.
    ///
    /// Sampling rather than using a fixed colour is what keeps the overlay
    /// from looking pasted on: dark-mode screens get dark patches, a coloured
    /// banner keeps its colour.
    static func averageColor(of image: UIImage, in rect: CGRect) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let scale = image.scale
        let pixelRect = CGRect(
            x: rect.origin.x * scale, y: rect.origin.y * scale,
            width: rect.width * scale, height: rect.height * scale
        ).integral

        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clamped = pixelRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = cgImage.cropping(to: clamped) else { return nil }

        // Averaging by drawing into a 1x1 context is far cheaper than reading
        // every pixel, and precision beyond this is invisible behind text.
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    /// Black or white, whichever the background can carry.
    static func contrastingTextColor(for background: UIColor) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .label
        }
        // Rec. 709 luma.
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.55 ? .black : .white
    }
}
