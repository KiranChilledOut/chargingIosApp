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
        /// How far text may spill past its box before it is clipped instead.
        public var maximumOverflow: Double

        public init(
            maximumFontScale: Double = 0.78,
            minimumFontSize: Double = 9,
            cornerRadius: Double = 3,
            inset: Double = 1.5,
            maximumOverflow: Double = 1.8
        ) {
            self.maximumFontScale = maximumFontScale
            self.minimumFontSize = minimumFontSize
            self.cornerRadius = cornerRadius
            self.inset = inset
            self.maximumOverflow = maximumOverflow
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
        return renderer.image { _ in
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

                let background = dominantColor(of: image, in: rect) ?? .systemBackground
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
                    style: style
                )
            }
        }
    }

    // MARK: - Text

    private static func draw(
        text: String,
        in rect: CGRect,
        color: UIColor,
        style: Style
    ) {
        let boxWidth = Double(rect.width)
        let boxHeight = Double(rect.height)
        let ceiling = max(style.minimumFontSize, boxHeight * style.maximumFontScale)

        // Wrap, never truncate. The estimate below can be optimistic, and with
        // a truncating style the overflow came out as "…" — the reader loses
        // the end of a sentence and cannot tell that they have.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        func measure(at size: Double) -> CGRect {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: CGFloat(size)),
                    .paragraphStyle: paragraph,
                ]
            )
            return attributed.boundingRect(
                with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }

        // `LayoutFitting` approximates character width, which is close enough
        // to start from but not to trust — the real font is often wider, and
        // the difference is exactly what overflowed the box. So take its answer
        // as an upper bound and shrink against real measurement until the text
        // genuinely fits.
        var size = LayoutFitting.fittedFontSize(
            text: text, boxWidth: boxWidth, boxHeight: boxHeight,
            maxFontSize: ceiling, minFontSize: style.minimumFontSize
        )
        while size > style.minimumFontSize,
              Double(measure(at: size).height) > boxHeight {
            size = max(style.minimumFontSize, size - 0.5)
        }

        let bounding = measure(at: size)

        // At the floor it may still not fit. Overflowing a little beats an
        // ellipsis: the words are all there, and a box on a screenshot has
        // whitespace around it more often than not.
        let drawHeight = min(bounding.height, rect.height * CGFloat(style.maximumOverflow))
        let y = rect.midY - drawHeight / 2

        NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: CGFloat(size)),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        ).draw(
            with: CGRect(
                x: rect.minX, y: y, width: rect.width, height: drawHeight
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    // MARK: - Colour sampling

    /// The region's dominant colour, used as the fill that hides the Dutch.
    ///
    /// The mean is the obvious choice and it is wrong. A bright green header
    /// with black lettering averages to a murky dark green, which then reads
    /// as a dark patch stamped on a light bar — and the contrast rule, seeing
    /// a dark fill, puts white text on it, compounding the mismatch.
    ///
    /// Background pixels outnumber glyph pixels on any realistic label, so the
    /// most common colour is the background. Sampling a small grid and taking
    /// the modal bucket gets it, cheaply.
    static func dominantColor(of image: UIImage, in rect: CGRect) -> UIColor? {
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

        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .none  // no blending of ink into ground
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Quantize to 32 levels per channel so near-identical background
        // pixels land in one bucket, then take the fullest bucket's mean.
        var counts: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            let existing = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (existing.count + 1, existing.r + r, existing.g + g, existing.b + b)
        }
        guard let winner = counts.values.max(by: { $0.count < $1.count }),
              winner.count > 0 else { return nil }

        return UIColor(
            red: CGFloat(winner.r / winner.count) / 255,
            green: CGFloat(winner.g / winner.count) / 255,
            blue: CGFloat(winner.b / winner.count) / 255,
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
