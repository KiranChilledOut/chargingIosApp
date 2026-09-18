import Foundation

/// Geometry for drawing English on top of where the Dutch was.
///
/// English is usually a little shorter than Dutch, but "usually" is not
/// "always" — Dutch compounds one long word where English needs three
/// ("verzekeringsmaatschappij" / "insurance company"). So every label gets
/// measured and, where needed, shrunk to fit its original box.
public enum LayoutFitting {

    /// Width of one character as a fraction of font size. 0.5 is a good
    /// approximation for the system sans-serif at UI sizes; the exact value
    /// only shifts where the shrink threshold lands.
    public static let defaultCharWidthRatio: Double = 0.5
    /// Line box height as a multiple of font size.
    public static let defaultLineHeightRatio: Double = 1.2

    /// Greedy word wrap. A word longer than the line is hard-broken rather
    /// than allowed to overflow.
    public static func wrap(_ text: String, maxCharsPerLine: Int) -> [String] {
        guard maxCharsPerLine > 0 else { return [text] }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""

        for word in words {
            var word = word
            // Hard-break anything that cannot fit on a line by itself.
            while word.count > maxCharsPerLine {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                let splitIndex = word.index(word.startIndex, offsetBy: maxCharsPerLine)
                lines.append(String(word[..<splitIndex]))
                word = String(word[splitIndex...])
            }

            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxCharsPerLine {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    public static func lineCount(
        text: String,
        fontSize: Double,
        boxWidth: Double,
        charWidthRatio: Double = defaultCharWidthRatio
    ) -> Int {
        guard fontSize > 0, boxWidth > 0 else { return 1 }
        let charWidth = fontSize * charWidthRatio
        let maxChars = Int(boxWidth / charWidth)
        guard maxChars > 0 else { return text.count }
        return max(1, wrap(text, maxCharsPerLine: maxChars).count)
    }

    /// Largest font size at which `text` fits inside the box, searched down
    /// from `maxFontSize` and clamped at `minFontSize`.
    ///
    /// Returns `minFontSize` when nothing fits; the caller decides whether to
    /// let it overflow or truncate, which is a display policy, not geometry.
    public static func fittedFontSize(
        text: String,
        boxWidth: Double,
        boxHeight: Double,
        maxFontSize: Double,
        minFontSize: Double = 8,
        charWidthRatio: Double = defaultCharWidthRatio,
        lineHeightRatio: Double = defaultLineHeightRatio
    ) -> Double {
        guard boxWidth > 0, boxHeight > 0, !text.isEmpty else { return maxFontSize }
        guard maxFontSize > minFontSize else { return minFontSize }

        var low = minFontSize
        var high = maxFontSize
        var best = minFontSize

        // Quarter-point precision is finer than anyone can see at UI sizes.
        while high - low > 0.25 {
            let candidate = (low + high) / 2
            let lines = lineCount(
                text: text, fontSize: candidate,
                boxWidth: boxWidth, charWidthRatio: charWidthRatio
            )
            let requiredHeight = Double(lines) * candidate * lineHeightRatio

            if requiredHeight <= boxHeight {
                best = candidate
                low = candidate
            } else {
                high = candidate
            }
        }

        // Confirm the top of the range rather than settling for the midpoint.
        let topLines = lineCount(
            text: text, fontSize: maxFontSize,
            boxWidth: boxWidth, charWidthRatio: charWidthRatio
        )
        if Double(topLines) * maxFontSize * lineHeightRatio <= boxHeight {
            return maxFontSize
        }
        return best
    }

    /// Makes runs that were the same size on the original screen the same
    /// size again.
    ///
    /// Each box is fitted on its own, so two rows of a rates table end up at
    /// whatever size their particular English happened to need — one label
    /// noticeably smaller than the one above it, for no reason the reader can
    /// see. The original screen had them equal, and the eye reads the
    /// difference as sloppiness.
    ///
    /// Runs are binned by how tall they stood originally, and every run in a
    /// bin takes the smallest size any of them needed — the only choice that
    /// leaves them all fitting.
    ///
    /// - Parameters:
    ///   - sizes: each run's independently fitted size, by id.
    ///   - heights: each run's original box height, by id.
    ///   - tolerance: how far two heights may differ and still count as the
    ///     same kind of text.
    public static func harmonize(
        sizes: [Int: Double],
        heights: [Int: Double],
        tolerance: Double = 0.22
    ) -> [Int: Double] {
        guard sizes.count > 1 else { return sizes }

        // Bin by height, largest first, so a heading anchors its own bin
        // rather than being absorbed into the body text below it.
        let ordered = heights
            .filter { sizes[$0.key] != nil && $0.value > 0 }
            .sorted { $0.value > $1.value }
        guard !ordered.isEmpty else { return sizes }

        var bins: [[Int]] = []
        var anchors: [Double] = []

        for (id, height) in ordered {
            if let index = anchors.firstIndex(where: { anchor in
                abs(height - anchor) / anchor <= tolerance
            }) {
                bins[index].append(id)
            } else {
                bins.append([id])
                anchors.append(height)
            }
        }

        var result = sizes
        for bin in bins where bin.count > 1 {
            let smallest = bin.compactMap { sizes[$0] }.min()
            guard let smallest else { continue }
            for id in bin { result[id] = smallest }
        }
        return result
    }

    /// Whether the English needs shrinking at all. Used to decide when to warn
    /// that a label may be clipped.
    public static func fitsAtNaturalSize(
        text: String,
        boxWidth: Double,
        boxHeight: Double,
        fontSize: Double,
        charWidthRatio: Double = defaultCharWidthRatio,
        lineHeightRatio: Double = defaultLineHeightRatio
    ) -> Bool {
        let lines = lineCount(
            text: text, fontSize: fontSize,
            boxWidth: boxWidth, charWidthRatio: charWidthRatio
        )
        return Double(lines) * fontSize * lineHeightRatio <= boxHeight
    }
}
