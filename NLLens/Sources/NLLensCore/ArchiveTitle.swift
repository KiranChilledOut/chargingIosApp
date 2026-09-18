import Foundation

/// Names a captured screen so it can be found again months later.
///
/// The archive is only worth keeping if you can find things in it, and a list
/// of timestamps is not findable. The heading is the best available name: it
/// is what the screen called itself, and `TypographyHints` already knows which
/// run was one, from how tall it stood.
public enum ArchiveTitle {

    public static let maxLength = 60

    public static func derive(from blocks: [TranslatedBlock]) -> String {
        let candidates = blocks.filter { isUsable($0.translatedText) }
        guard !candidates.isEmpty else { return "Untitled screen" }

        let roles = TypographyHints.roles(for: blocks)

        // A heading, if the screen had one.
        if let heading = candidates.first(where: { roles[$0.id] == .heading }) {
            return shorten(heading.translatedText)
        }
        // Otherwise the first line substantial enough to mean something — a
        // lone "OK" or "Back" names nothing.
        if let substantial = candidates.first(where: { $0.translatedText.count >= 12 }) {
            return shorten(substantial.translatedText)
        }
        return shorten(candidates[0].translatedText)
    }

    /// True when a line could serve as a name: it has words, and is not just
    /// a number, a price or a timestamp.
    static func isUsable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return TextNormalization.isTranslatable(trimmed)
    }

    /// Trims to length on a word boundary, so a title never ends mid-word.
    static func shorten(_ text: String, to limit: Int = maxLength) -> String {
        let clean = TextNormalization.collapseWhitespace(text)
        guard clean.count > limit else { return clean }

        let cut = clean.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > limit / 2 {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}
