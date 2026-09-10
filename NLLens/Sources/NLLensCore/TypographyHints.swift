import Foundation

/// What a run of text appears to be, judged by how tall it was on screen.
public enum TextRole: String, Sendable, Equatable {
    case heading
    case body
    case caption
}

/// Recovers document structure from the geometry OCR gives us.
///
/// Reading mode shows text rather than a picture of text, which means the
/// visual hierarchy of the original screen — what was a heading, what was
/// fine print — is otherwise thrown away, and a long screen becomes an
/// undifferentiated wall. The recognizer does not report font sizes, but the
/// height of each line's box is a good proxy, so scale each line against the
/// median for the document.
///
/// Judged relatively rather than against fixed thresholds because the absolute
/// numbers are normalized per capture and vary with device and screenshot
/// scale; what stays stable is that a heading is markedly taller than the
/// body around it.
public enum TypographyHints {

    /// A line this many times the median height reads as a heading.
    public static let headingRatio: Double = 1.35
    /// Below this, it reads as fine print.
    public static let captionRatio: Double = 0.78

    public static func roles(for blocks: [TranslatedBlock]) -> [Int: TextRole] {
        guard blocks.count > 2 else {
            // Too little to establish a baseline; treat everything as body
            // rather than inventing a hierarchy from two samples.
            return Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, TextRole.body) })
        }

        let heights = blocks.map(\.box.height).sorted()
        let median = heights[heights.count / 2]
        guard median > 0 else {
            return Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, TextRole.body) })
        }

        var roles: [Int: TextRole] = [:]
        for block in blocks {
            let ratio = block.box.height / median
            if ratio >= headingRatio {
                roles[block.id] = .heading
            } else if ratio <= captionRatio {
                roles[block.id] = .caption
            } else {
                roles[block.id] = .body
            }
        }
        return roles
    }

    /// The whole document as plain text, for copying out.
    ///
    /// Headings get a blank line before them so the structure survives being
    /// pasted somewhere with no formatting.
    public static func plainText(
        for blocks: [TranslatedBlock],
        includingSource: Bool = false
    ) -> String {
        let roles = roles(for: blocks)
        var lines: [String] = []

        for block in blocks {
            if roles[block.id] == .heading, !lines.isEmpty {
                lines.append("")
            }
            if includingSource, block.sourceText != block.translatedText {
                lines.append("\(block.translatedText)  [\(block.sourceText)]")
            } else {
                lines.append(block.translatedText)
            }
        }
        return lines.joined(separator: "\n")
    }
}
