import Foundation
import UIKit
import NLLensCore

/// Draws the English back onto the screenshot, in the place the Dutch was.
///
/// The alternative — a list of translated strings — loses the thing that makes
/// a screen readable, which is knowing which label belongs to which control.
/// So each translated run is painted over its original box, on a background
/// taken from the pixels around it so it reads as part of the screen rather
/// than a sticky note.
public enum OverlayRenderer {

    public struct Style: Sendable {
        /// Cap on drawn text size, as a fraction of its box height.
        public var maximumFontScale: Double
        public var minimumFontSize: Double
        public var cornerRadius: Double
        /// Padding around each replaced box.
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

        // Runs whose text did not change — numbers, prices, brand names — keep
        // their original pixels. Painting them would only risk covering them
        // with a worse rendering of themselves.
        let changed = blocks.filter { $0.translatedText != $0.sourceText }
        guard !changed.isEmpty else { return image }

        // Pass one: work out how big each run has to be. Done before drawing
        // because sizes have to be reconciled across runs, and a run cannot be
        // drawn until it knows what the others needed.
        var rects: [Int: CGRect] = [:]
        var required: [Int: Double] = [:]
        var heights: [Int: Double] = [:]

        for block in changed {
            let rect = CGRect(
                x: block.box.x * size.width,
                y: block.box.y * size.height,
                width: block.box.width * size.width,
                height: block.box.height * size.height
            ).insetBy(dx: -style.inset, dy: -style.inset)

            guard rect.width > 2, rect.height > 2 else { continue }
            rects[block.id] = rect
            heights[block.id] = block.box.height
            required[block.id] = requiredFontSize(
                text: block.translatedText, in: rect, style: style
            )
        }

        let sizes = LayoutFitting.harmonize(sizes: required, heights: heights)

        // Pass two: draw.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))

            for block in changed {
                guard let rect = rects[block.id],
                      let fontSize = sizes[block.id] else { continue }

                let background = backgroundColor(of: image, around: rect) ?? .systemBackground
                let foreground = contrastingTextColor(for: background)

                background.setFill()
                UIBezierPath(
                    roundedRect: rect, cornerRadius: style.cornerRadius
                ).fill()

                draw(
                    text: block.translatedText,
                    in: rect.insetBy(dx: style.inset, dy: 0),
                    color: foreground,
                    fontSize: fontSize,
                    style: style
                )
            }
        }
    }

    // MARK: - Text

    private static func paragraphStyle() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        // Wrap, never truncate. A truncated line ends in "…" and the reader
        // loses the end of a sentence without being able to tell.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        return paragraph
    }

    private static func measure(
        _ text: String, at fontSize: Double, width: CGFloat
    ) -> CGRect {
        NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: CGFloat(fontSize)),
                .paragraphStyle: paragraphStyle(),
            ]
        ).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    /// The largest size at which this text really fits its box.
    ///
    /// `LayoutFitting` approximates character width, which is close enough to
    /// start from but not to trust — the real font is usually wider, and that
    /// difference is what overflowed the box and got truncated away. So its
    /// answer is an upper bound, shrunk against real measurement.
    static func requiredFontSize(
        text: String, in rect: CGRect, style: Style
    ) -> Double {
        let boxHeight = Double(rect.height)
        let ceiling = max(style.minimumFontSize, boxHeight * style.maximumFontScale)

        var size = LayoutFitting.fittedFontSize(
            text: text, boxWidth: Double(rect.width), boxHeight: boxHeight,
            maxFontSize: ceiling, minFontSize: style.minimumFontSize
        )
        while size > style.minimumFontSize,
              Double(measure(text, at: size, width: rect.width).height) > boxHeight {
            size = max(style.minimumFontSize, size - 0.5)
        }
        return size
    }

    private static func draw(
        text: String,
        in rect: CGRect,
        color: UIColor,
        fontSize: Double,
        style: Style
    ) {
        let bounding = measure(text, at: fontSize, width: rect.width)

        // At the floor it may still not fit. Overflowing a little beats an
        // ellipsis: the words are all there, and a label on a screenshot
        // usually has whitespace around it.
        let drawHeight = min(bounding.height, rect.height * CGFloat(style.maximumOverflow))

        NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: CGFloat(fontSize)),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle(),
            ]
        ).draw(
            with: CGRect(
                x: rect.minX,
                y: rect.midY - drawHeight / 2,
                width: rect.width,
                height: drawHeight
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    // MARK: - Colour

    /// The colour behind a run, sampled from beside it rather than under it.
    ///
    /// Sampling the box itself fails on exactly the text that matters most: a
    /// large bold heading fills its box with glyphs, so the ink outnumbers the
    /// ground and the "dominant" colour comes back as the letters. A green
    /// header then gets a black patch stamped on it, with white text, and the
    /// result looks broken.
    ///
    /// The strips immediately above and below a line are almost always the
    /// surface it sits on, whatever that surface is.
    static func backgroundColor(of image: UIImage, around rect: CGRect) -> UIColor? {
        let margin = max(3, rect.height * 0.45)
        let strips = [
            CGRect(x: rect.minX, y: rect.minY - margin, width: rect.width, height: margin),
            CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: margin),
        ]

        if let sampled = dominantColor(of: image, in: strips) { return sampled }
        // Nothing usable beside it — a run at the very edge of the screen.
        return dominantColor(of: image, in: [rect])
    }

    /// The most common colour across the given regions.
    ///
    /// The mean is the obvious choice and it is wrong: a bright bar with dark
    /// lettering averages to a murky middle that matches neither. Background
    /// pixels outnumber glyph pixels, so the fullest bucket is the ground.
    static func dominantColor(of image: UIImage, in rects: [CGRect]) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let scale = image.scale
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        var counts: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]

        for rect in rects {
            let pixelRect = CGRect(
                x: rect.origin.x * scale, y: rect.origin.y * scale,
                width: rect.width * scale, height: rect.height * scale
            ).integral.intersection(bounds)

            guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
                  let cropped = cgImage.cropping(to: pixelRect) else { continue }

            let side = 8
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            guard let context = CGContext(
                data: &pixels, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            // No interpolation: blending ink into ground would invent colours
            // that are on neither.
            context.interpolationQuality = .none
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

            // Quantize to 32 levels per channel so near-identical background
            // pixels land in one bucket.
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[index])
                let g = Int(pixels[index + 1])
                let b = Int(pixels[index + 2])
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                let existing = counts[key] ?? (0, 0, 0, 0)
                counts[key] = (existing.count + 1, existing.r + r, existing.g + g, existing.b + b)
            }
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
