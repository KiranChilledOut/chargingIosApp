import Foundation

/// Normalization and stable hashing used for cache keys.
///
/// The cache is the difference between a 2-second round trip and an instant
/// answer on the twenty screens you see every day, so the key has to be
/// forgiving of the ways OCR renders the same label differently between runs
/// — without being so forgiving that two genuinely different strings collide.
public enum TextNormalization {

    /// Characters OCR swaps around freely between passes. Folding these makes
    /// the same on-screen label hash identically run to run.
    private static let punctuationFolding: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201B}": "'", "\u{02BC}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201F}": "\"",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-",
        "\u{2013}": "-", "\u{2014}": "-", "\u{2015}": "-", "\u{2212}": "-",
        "\u{00A0}": " ", "\u{2007}": " ", "\u{202F}": " ",
    ]

    /// Invisible characters that carry no meaning but break equality.
    private static let zeroWidth: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}",
    ]

    /// Cleans text for **display**: fixes spacing and punctuation noise but
    /// preserves case and meaning. Safe to show to the user.
    public static func clean(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        for ch in input {
            if zeroWidth.contains(ch) { continue }
            result.append(punctuationFolding[ch] ?? ch)
        }
        return collapseWhitespace(result)
    }

    /// Collapses runs of whitespace to a single space and trims the ends.
    public static func collapseWhitespace(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var pendingSpace = false
        var started = false

        for ch in input {
            if ch.isWhitespace || ch.isNewline {
                if started { pendingSpace = true }
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(ch)
            started = true
        }
        return result
    }

    /// Produces the **cache key** form: cleaned, case-folded, NFC-composed.
    ///
    /// Case is folded because Dutch UI labels translate identically regardless
    /// of capitalization ("Openen" / "openen"), and folding roughly doubles the
    /// hit rate on real screens.
    public static func cacheKeyForm(_ input: String) -> String {
        let cleaned = clean(input)
        let composed = cleaned.precomposedStringWithCanonicalMapping
        return composed.lowercased()
    }

    /// FNV-1a 64-bit over UTF-8 bytes.
    ///
    /// Swift's built-in `Hasher` is seeded per-process, so it cannot be used
    /// for anything written to disk. This is deterministic across launches,
    /// devices and platforms, which is exactly what a persistent cache needs.
    public static func stableHash(_ input: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Cache key for a source string: normalized, hashed, hex-encoded.
    public static func cacheKey(_ input: String) -> String {
        String(stableHash(cacheKeyForm(input)), radix: 16)
    }

    /// True when a recognized run carries no translatable content — pure
    /// digits, punctuation, currency, times. Sending these to the model wastes
    /// tokens and invites the model to "helpfully" rewrite numbers.
    public static func isTranslatable(_ input: String) -> Bool {
        let cleaned = clean(input)
        guard !cleaned.isEmpty else { return false }

        // Needs at least two consecutive letters to be a word worth translating.
        var consecutiveLetters = 0
        for ch in cleaned {
            if ch.isLetter {
                consecutiveLetters += 1
                if consecutiveLetters >= 2 { return true }
            } else {
                consecutiveLetters = 0
            }
        }
        return false
    }
}
