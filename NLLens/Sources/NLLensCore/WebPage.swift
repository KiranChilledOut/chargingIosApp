import Foundation

/// Turns a fetched HTML page into something worth spending context on.
///
/// The reason this exists: Tavily returns roughly 400 characters per result,
/// and the figure someone actually needs — the 2026 rate, the threshold, the
/// notice period — is usually in a table several paragraphs below whatever the
/// snippet caught. Without a way to read the page, an answer can only ever be
/// as good as the summary, which is how "what is the average rate" ends up
/// answered with a sentence about tariffs in general.
///
/// Deliberately not an HTML parser. It does not need to be correct about
/// markup, only about which text a reader would have seen, and a real parser
/// is a dependency this package does not otherwise need.
public enum WebPage {

    /// Readable text from an HTML document.
    public static func text(fromHTML html: String, limit: Int = 12_000) -> String {
        var working = html

        // Whole elements whose content is never read by a person. Dropped
        // before tag-stripping, or their contents survive as a wall of
        // JavaScript that looks like prose to a model.
        for tag in ["script", "style", "noscript", "svg", "head", "iframe"] {
            working = removeElements(named: tag, in: working)
        }

        // Structure that carries meaning gets a line break before the tags go,
        // otherwise every heading, row and list item runs into the next and a
        // table of rates becomes one unreadable paragraph.
        for pattern in [
            "(?i)<br[^>]*>", "(?i)</p>", "(?i)</div>", "(?i)</li>", "(?i)</tr>",
            "(?i)</h[1-6]>", "(?i)</table>", "(?i)</section>",
        ] {
            working = replacing(pattern, in: working, with: "\n")
        }
        // Cells separated, so a rate keeps company with its label.
        working = replacing("(?i)</t[dh]>", in: working, with: " \u{2502} ")

        working = replacing("<[^>]+>", in: working, with: " ")
        working = decodeEntities(working)

        let lines = working
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { TextNormalization.collapseWhitespace(String($0)) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var kept: [String] = []
        for line in lines {
            // Navigation and cookie banners repeat the same short strings many
            // times over; one copy is plenty.
            if line.count < 40, !seen.insert(line).inserted { continue }
            kept.append(line)
        }

        let joined = kept.joined(separator: "\n")
        guard joined.count > limit else { return joined }

        let cut = joined.prefix(limit)
        // Cut at a line so a number is never split from its label.
        if let lastBreak = cut.lastIndex(of: "\n") {
            return String(cut[..<lastBreak]) + "\n…"
        }
        return String(cut) + "…"
    }

    static func removeElements(named tag: String, in html: String) -> String {
        replacing("(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: html, with: " ")
    }

    static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&euro;": "€", "&pound;": "£", "&hellip;": "…",
        "&mdash;": "—", "&ndash;": "–", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&eacute;": "é", "&egrave;": "è",
        "&uuml;": "ü", "&ouml;": "ö", "&auml;": "ä", "&iuml;": "ï", "&#39;": "'",
    ]

    /// Entities matter more here than they look. A Dutch page writes prices
    /// with `&euro;` and `&nbsp;`, and leaving those raw puts literal
    /// "&euro;" next to every figure the model is meant to read.
    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(
                of: entity, with: replacement, options: .caseInsensitive
            )
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else {
            return result
        }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let flagRange = Range(match.range(at: 1), in: result),
                  let digitsRange = Range(match.range(at: 2), in: result)
            else { continue }

            let isHex = !result[flagRange].isEmpty
            let digits = String(result[digitsRange])
            guard let value = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value)
            else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return result
    }
}
