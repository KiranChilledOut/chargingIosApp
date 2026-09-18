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
        /// Most interrupting blocks that may be stepped over in one group.
        public var maxAsidesPerGroup: Int

        public init(
            maxLineGapRatio: Double = 0.8,
            minHorizontalOverlap: Double = 0.3,
            maxHeightRatio: Double = 1.6,
            maxLinesPerGroup: Int = 8,
            maxCharactersPerGroup: Int = 400,
            maxAsidesPerGroup: Int = 2
        ) {
            self.maxLineGapRatio = maxLineGapRatio
            self.minHorizontalOverlap = minHorizontalOverlap
            self.maxHeightRatio = maxHeightRatio
            self.maxLinesPerGroup = maxLinesPerGroup
            self.maxCharactersPerGroup = maxCharactersPerGroup
            self.maxAsidesPerGroup = maxAsidesPerGroup
        }

        public static let `default` = Options()
    }

    /// Groups blocks into paragraphs, preserving reading order.
    ///
    /// A group's union box is what gets painted over on the rendered screen,
    /// so it must never grow to enclose a block outside the group. On a
    /// label/value layout the labels sit in a left column and read exactly
    /// like a paragraph — merging two of them produces a box spanning the full
    /// width, which then paints over the values on the right and destroys
    /// them. `wouldSwallowOutsider` is the guard.
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

        // Blocks that interrupt a paragraph without belonging to it — an icon
        // in the margin, a badge beside a heading — are set aside rather than
        // ending the group. Closing on the first stray is what splits a
        // two-line date across two boxes when a bolt icon happens to sit
        // between the lines, leaving the second line untranslated on screen.
        var strays: [TextBlock] = []

        for block in sorted.dropFirst() {
            let fits = current.count < options.maxLinesPerGroup
                && currentLength + block.text.count <= options.maxCharactersPerGroup

            if fits, let previous = current.last,
               belongTogether(previous, block, options: options),
               !wouldSwallowOutsider(current + [block], among: sorted) {
                current.append(block)
                currentLength += block.text.count
                continue
            }

            // Narrow and clear of the column the paragraph occupies: almost
            // certainly decoration beside it, not the next paragraph.
            if !strays.isEmpty || current.count >= 1,
               isAside(block, from: current, options: options),
               strays.count < options.maxAsidesPerGroup {
                strays.append(block)
                continue
            }

            groups.append(current)
            groups.append(contentsOf: strays.map { [$0] })
            strays.removeAll()
            current = [block]
            currentLength = block.text.count
        }
        groups.append(contentsOf: strays.map { [$0] })
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

    /// Whether merging these blocks would produce a box enclosing something
    /// that is not one of them.
    ///
    /// This is what keeps a column of labels from merging on a rates screen:
    /// two stacked labels union into a band spanning the whole row, and the
    /// amounts to their right fall inside it. Painting that band over the
    /// screen would erase the numbers, which is worse than any layout gain
    /// from merging.
    static func wouldSwallowOutsider(_ group: [TextBlock], among all: [TextBlock]) -> Bool {
        guard let first = group.first, group.count > 1 else { return false }
        let union = group.dropFirst().reduce(first.box) { $0.union($1.box) }
        let members = Set(group.map(\.id))

        for block in all where !members.contains(block.id) {
            let overlapX = Swift.max(
                0, Swift.min(union.maxX, block.box.maxX) - Swift.max(union.x, block.box.x)
            )
            let overlapY = Swift.max(
                0, Swift.min(union.maxY, block.box.maxY) - Swift.max(union.y, block.box.y)
            )
            let area = block.box.width * block.box.height
            guard area > 0 else { continue }

            // More than half of an outsider inside the union means the paint
            // would cover it.
            if (overlapX * overlapY) / area > 0.5 { return true }
        }
        return false
    }

    /// Whether a block sits beside a paragraph rather than continuing it.
    ///
    /// Two conditions, both required: it is appreciably narrower than the
    /// column, and it barely overlaps that column horizontally. An icon in the
    /// margin satisfies both; the next paragraph satisfies neither.
    static func isAside(
        _ block: TextBlock,
        from group: [TextBlock],
        options: Options
    ) -> Bool {
        guard let first = group.first else { return false }
        let column = group.dropFirst().reduce(first.box) { $0.union($1.box) }

        guard column.width > 0, block.box.width < column.width * 0.5 else { return false }

        let overlapStart = Swift.max(column.x, block.box.x)
        let overlapEnd = Swift.min(column.maxX, block.box.maxX)
        let overlap = Swift.max(0, overlapEnd - overlapStart)
        return overlap / block.box.width < 0.5
    }

    static func belongTogether(
        _ first: TextBlock,
        _ second: TextBlock,
        options: Options
    ) -> Bool {
        // A line ending in a colon is a label, complete in itself. On a rates
        // or contract screen the labels stack in a left column and read
        // exactly like a paragraph, so without this they merge into one run
        // and the screen's structure is lost.
        if first.text.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
            return false
        }

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
