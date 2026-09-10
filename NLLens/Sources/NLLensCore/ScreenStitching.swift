import Foundation

/// Several captured screens merged into one continuous document.
public struct StitchedDocument: Sendable, Equatable {
    /// Blocks in reading order, renumbered from zero.
    public var blocks: [TranslatedBlock]
    public var screenCount: Int
    /// Lines dropped because consecutive captures overlapped.
    public var duplicatesRemoved: Int

    public init(blocks: [TranslatedBlock], screenCount: Int, duplicatesRemoved: Int = 0) {
        self.blocks = blocks
        self.screenCount = screenCount
        self.duplicatesRemoved = duplicatesRemoved
    }
}

/// Joins screenshots taken while scrolling into one document.
///
/// Anything longer than a screen has to be captured in pieces, and people do
/// not scroll by exactly one screen height — they overlap, deliberately, so
/// they do not miss a line. Naively concatenating the captures repeats
/// whatever sat in the overlap, which is precisely the part the reader is
/// mid-sentence on.
///
/// So consecutive captures are joined by finding the longest run where the end
/// of one matches the start of the next, and dropping the repeat.
///
/// Note that bounding boxes are normalized per capture, so once merged they no
/// longer describe one coordinate space. A stitched document is for reading,
/// not for drawing an overlay.
public enum ScreenStitching {

    /// Merges captures given in the order they were taken.
    public static func merge(_ screens: [[TranslatedBlock]]) -> StitchedDocument {
        let nonEmpty = screens.filter { !$0.isEmpty }
        guard let first = nonEmpty.first else {
            return StitchedDocument(blocks: [], screenCount: screens.count)
        }

        var merged = first
        var removed = 0

        for next in nonEmpty.dropFirst() {
            let overlap = overlapLength(
                merged.map { key($0) },
                next.map { key($0) }
            )
            removed += overlap
            merged.append(contentsOf: next.dropFirst(overlap))
        }

        // Ids were per-capture, so they collide once merged.
        let renumbered = merged.enumerated().map { index, block in
            TranslatedBlock(
                id: index,
                sourceText: block.sourceText,
                translatedText: block.translatedText,
                box: block.box,
                fromCache: block.fromCache
            )
        }

        return StitchedDocument(
            blocks: renumbered,
            screenCount: nonEmpty.count,
            duplicatesRemoved: removed
        )
    }

    /// The largest `k` where the last `k` entries of `a` equal the first `k` of
    /// `b`. Zero when the captures do not overlap.
    ///
    /// Searches longest-first so that a genuine multi-line overlap wins over an
    /// incidental single-line match — two screens both ending and starting with
    /// "Annuleren" is common, two screens sharing four consecutive lines is not.
    static func overlapLength(_ a: [String], _ b: [String]) -> Int {
        let limit = min(a.count, b.count)
        guard limit > 0 else { return 0 }

        var k = limit
        while k > 0 {
            if Array(a.suffix(k)) == Array(b.prefix(k)) { return k }
            k -= 1
        }
        return 0
    }

    /// Comparison key. Uses the same normalization as the cache so that two
    /// captures of the same line — which OCR may render with slightly
    /// different spacing or quote characters — compare equal.
    private static func key(_ block: TranslatedBlock) -> String {
        TextNormalization.cacheKeyForm(block.sourceText)
    }
}
