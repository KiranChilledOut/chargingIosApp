import Foundation

/// Merges per-line OCR output into paragraphs.
///
/// Vision reports one box per visual line. Translating lines in isolation
/// produces exactly the disjointed output that makes machine translation feel
/// broken — and for Dutch it is worse than usual, because the verb routinely
/// lands at the end of a clause that the recognizer split across two lines.
/// Grouping lines into paragraphs first gives the model whole sentences.
public enum BlockGrouping {

    public struct Options: Sendable {
        /// Max vertical gap between lines, as a multiple of line height.
        public var maxLineGapRatio: Double
        /// Minimum horizontal overlap for two lines to belong together.
        public var minHorizontalOverlap: Double
        /// Lines differing more than this in height are different elements.
        public var maxHeightRatio: Double
        /// Most lines one group may hold.
        public var maxLinesPerGroup: Int
        /// Most characters one group may hold.
        public var maxCharactersPerGroup: Int

        public init(
            maxLineGapRatio: Double = 0.8,
            minHorizontalOverlap: Double = 0.3,
            maxHeightRatio: Double = 1.6,
            maxLinesPerGroup: Int = 8,
            maxCharactersPerGroup: Int = 400
        ) {
            self.maxLineGapRatio = maxLineGapRatio
            self.minHorizontalOverlap = minHorizontalOverlap
            self.maxHeightRatio = maxHeightRatio
            self.maxLinesPerGroup = maxLinesPerGroup
            self.maxCharactersPerGroup = maxCharactersPerGroup
        }

        public static let `default` = Options()
    }

    /// Groups blocks into paragraphs, preserving reading order.
    ///
    /// Groups are capped in both lines and characters. Without a cap a page of
    /// prose merges into a single block, which then rides on one translation
    /// unit — and a model handed one very long string will paraphrase or
    /// shorten it, so whole sentences vanish with nothing to detect the loss
    /// against. Capping keeps each unit small enough that the model renders it
    /// rather than summarising it.
    public static func group(
        _ blocks: [TextBlock],
        options: Options = .default
    ) -> [TextBlock] {
        guard blocks.count > 1 else { return blocks }

        let sorted = blocks.sorted {
            // Same visual row when boxes overlap vertically; then left to right.
            if abs($0.box.y - $1.box.y) < min($0.box.height, $1.box.height) * 0.5 {
                return $0.box.x < $1.box.x
            }
            return $0.box.y < $1.box.y
        }

        var groups: [[TextBlock]] = []
        var current: [TextBlock] = [sorted[0]]
        var currentLength = sorted[0].text.count

        for block in sorted.dropFirst() {
            let fits = current.count < options.maxLinesPerGroup
                && currentLength + block.text.count <= options.maxCharactersPerGroup

            if fits, let previous = current.last,
               belongTogether(previous, block, options: options) {
                current.append(block)
                currentLength += block.text.count
            } else {
                groups.append(current)
                current = [block]
                currentLength = block.text.count
            }
        }
        groups.append(current)

        return groups.enumerated().map { index, group in
            let text = group.map(\.text).joined(separator: " ")
            let box = group.dropFirst().reduce(group[0].box) { $0.union($1.box) }
            let confidence = group.map(\.confidence).reduce(0, +) / Double(group.count)
            return TextBlock(
                id: index,
                text: TextNormalization.collapseWhitespace(text),
                box: box,
                confidence: confidence
            )
        }
    }

    static func belongTogether(
        _ first: TextBlock,
        _ second: TextBlock,
        options: Options
    ) -> Bool {
        let a = first.box
        let b = second.box

        // Comparable text size.
        let heightRatio = max(a.height, b.height) / max(0.0001, min(a.height, b.height))
        guard heightRatio <= options.maxHeightRatio else { return false }

        // Close enough vertically to be the next line of the same paragraph.
        let gap = a.verticalGap(to: b)
        guard gap >= -a.height, gap <= a.height * options.maxLineGapRatio else { return false }

        // Sharing a column, not sitting side by side in different ones.
        let overlapStart = max(a.x, b.x)
        let overlapEnd = min(a.maxX, b.maxX)
        let overlap = overlapEnd - overlapStart
        guard overlap > 0 else { return false }

        let narrower = min(a.width, b.width)
        guard narrower > 0 else { return false }
        return overlap / narrower >= options.minHorizontalOverlap
    }
}
