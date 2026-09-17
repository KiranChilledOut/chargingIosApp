import XCTest
@testable import NLLensCore

final class LayoutFittingTests: XCTestCase {

    func testWrapRespectsLineWidth() {
        let lines = LayoutFitting.wrap("the quick brown fox jumps", maxCharsPerLine: 10)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 10, "overlong line: \(line)")
        }
        XCTAssertEqual(lines.joined(separator: " "), "the quick brown fox jumps")
    }

    func testLongWordIsHardBroken() {
        // Dutch compounds are exactly this case.
        let lines = LayoutFitting.wrap("verzekeringsmaatschappij", maxCharsPerLine: 8)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 8)
        }
        XCTAssertEqual(lines.joined(), "verzekeringsmaatschappij")
    }

    func testShortTextKeepsMaximumFontSize() {
        let size = LayoutFitting.fittedFontSize(
            text: "OK", boxWidth: 200, boxHeight: 40, maxFontSize: 17
        )
        XCTAssertEqual(size, 17, accuracy: 0.01)
    }

    func testLongTextIsShrunkToFit() {
        let size = LayoutFitting.fittedFontSize(
            text: "This is a considerably longer piece of English text than the box wants",
            boxWidth: 120, boxHeight: 22, maxFontSize: 17
        )
        XCTAssertLessThan(size, 17)
        XCTAssertGreaterThanOrEqual(size, 8)
    }

    func testFittedSizeActuallyFits() {
        let text = "Insurance company payment overview"
        let width = 150.0
        let height = 40.0
        let size = LayoutFitting.fittedFontSize(
            text: text, boxWidth: width, boxHeight: height, maxFontSize: 20
        )
        XCTAssertTrue(
            LayoutFitting.fitsAtNaturalSize(
                text: text, boxWidth: width, boxHeight: height, fontSize: size
            ),
            "fittedFontSize returned \(size), which does not fit"
        )
    }

    func testNeverGoesBelowMinimum() {
        let size = LayoutFitting.fittedFontSize(
            text: String(repeating: "long ", count: 200),
            boxWidth: 20, boxHeight: 10, maxFontSize: 17, minFontSize: 9
        )
        XCTAssertEqual(size, 9, accuracy: 0.01)
    }

    func testEmptyTextIsSafe() {
        let size = LayoutFitting.fittedFontSize(
            text: "", boxWidth: 100, boxHeight: 20, maxFontSize: 14
        )
        XCTAssertEqual(size, 14, accuracy: 0.01)
    }

    func testZeroSizedBoxDoesNotDivideByZero() {
        let size = LayoutFitting.fittedFontSize(
            text: "hello", boxWidth: 0, boxHeight: 0, maxFontSize: 14
        )
        XCTAssertEqual(size, 14, accuracy: 0.01)
    }
}

final class BlockGroupingTests: XCTestCase {

    private func line(_ id: Int, _ text: String, y: Double, x: Double = 0.1, width: Double = 0.6) -> TextBlock {
        TextBlock(
            id: id, text: text,
            box: BoundingBox(x: x, y: y, width: width, height: 0.03),
            confidence: 1
        )
    }

    func testConsecutiveLinesMergeIntoParagraph() {
        let blocks = [
            line(0, "Wij hebben uw betaling", y: 0.10),
            line(1, "niet kunnen verwerken.", y: 0.14),
        ]
        let grouped = BlockGrouping.group(blocks)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].text, "Wij hebben uw betaling niet kunnen verwerken.")
    }

    func testDistantLinesStaySeparate() {
        let blocks = [
            line(0, "Kop", y: 0.10),
            line(1, "Ver weg", y: 0.70),
        ]
        XCTAssertEqual(BlockGrouping.group(blocks).count, 2)
    }

    func testSideBySideColumnsDoNotMerge() {
        let blocks = [
            line(0, "Links", y: 0.20, x: 0.05, width: 0.25),
            line(1, "Rechts", y: 0.24, x: 0.65, width: 0.25),
        ]
        XCTAssertEqual(BlockGrouping.group(blocks).count, 2, "different columns")
    }

    func testDifferentTextSizesDoNotMerge() {
        let heading = TextBlock(
            id: 0, text: "Titel",
            box: BoundingBox(x: 0.1, y: 0.1, width: 0.5, height: 0.08)
        )
        let body = TextBlock(
            id: 1, text: "kleine tekst",
            box: BoundingBox(x: 0.1, y: 0.19, width: 0.5, height: 0.02)
        )
        XCTAssertEqual(BlockGrouping.group([heading, body]).count, 2)
    }

    func testMergedBoxCoversBothLines() {
        let blocks = [
            line(0, "Een", y: 0.10),
            line(1, "Twee", y: 0.14),
        ]
        let grouped = BlockGrouping.group(blocks)
        XCTAssertEqual(grouped.count, 1)
        let box = grouped[0].box
        XCTAssertLessThanOrEqual(box.y, 0.10)
        XCTAssertGreaterThanOrEqual(box.maxY, 0.17 - 0.0001)
    }

    func testSingleBlockPassesThroughUnchanged() {
        let blocks = [line(0, "Alleen", y: 0.3)]
        XCTAssertEqual(BlockGrouping.group(blocks).count, 1)
    }

    func testGroupingIsStableForEmptyInput() {
        XCTAssertTrue(BlockGrouping.group([]).isEmpty)
    }
}

final class BoundingBoxTests: XCTestCase {

    func testVisionRectIsFlippedToTopLeftOrigin() {
        // A box at the BOTTOM in Vision coordinates (low y) must land at the
        // BOTTOM in top-left coordinates (high y).
        let bottom = BoundingBox.fromVisionNormalized(x: 0.1, y: 0.05, width: 0.3, height: 0.1)
        XCTAssertEqual(bottom.y, 0.85, accuracy: 0.0001)

        // A box at the TOP in Vision coordinates (high y) lands near y = 0.
        let top = BoundingBox.fromVisionNormalized(x: 0.1, y: 0.85, width: 0.3, height: 0.1)
        XCTAssertEqual(top.y, 0.05, accuracy: 0.0001)
    }

    func testFlipPreservesWidthHeightAndX() {
        let box = BoundingBox.fromVisionNormalized(x: 0.2, y: 0.3, width: 0.4, height: 0.05)
        XCTAssertEqual(box.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(box.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.05, accuracy: 0.0001)
    }

    func testFlipIsItsOwnInverse() {
        let original = BoundingBox.fromVisionNormalized(x: 0.1, y: 0.25, width: 0.5, height: 0.2)
        let roundTrip = BoundingBox.fromVisionNormalized(
            x: original.x, y: original.y, width: original.width, height: original.height
        )
        XCTAssertEqual(roundTrip.y, 0.25, accuracy: 0.0001)
    }

    func testFullHeightBoxStartsAtZero() {
        let box = BoundingBox.fromVisionNormalized(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(box.y, 0, accuracy: 0.0001)
    }

    func testUnionCoversBothBoxes() {
        let a = BoundingBox(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let b = BoundingBox(x: 0.15, y: 0.3, width: 0.3, height: 0.1)
        let union = a.union(b)
        XCTAssertEqual(union.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(union.y, 0.1, accuracy: 0.0001)
        XCTAssertEqual(union.maxX, 0.45, accuracy: 0.0001)
        XCTAssertEqual(union.maxY, 0.4, accuracy: 0.0001)
    }
}

/// A group becomes one translation unit. Let it grow without limit and a page
/// of prose arrives at the model as a single enormous string, which it will
/// paraphrase rather than render — losing whole sentences with nothing to
/// detect the loss against.
final class BlockGroupingCapTests: XCTestCase {

    /// Consecutive lines close enough that grouping wants to merge them all.
    private func paragraph(lines: Int, text: String = "een regel tekst") -> [TextBlock] {
        (0..<lines).map { index in
            TextBlock(
                id: index, text: text,
                box: BoundingBox(
                    x: 0.1, y: Double(index) * 0.04, width: 0.8, height: 0.03
                )
            )
        }
    }

    func testLongParagraphIsSplitByLineCount() {
        let grouped = BlockGrouping.group(paragraph(lines: 30))
        XCTAssertGreaterThan(grouped.count, 1, "30 lines must not become one unit")
        for group in grouped {
            XCTAssertLessThanOrEqual(
                group.text.count, BlockGrouping.Options.default.maxCharactersPerGroup + 40,
                "group overshot the character cap"
            )
        }
    }

    func testCharacterCapSplitsEvenFewLines() {
        let long = String(repeating: "lang ", count: 60)   // ~300 chars each
        let grouped = BlockGrouping.group(paragraph(lines: 4, text: long))
        XCTAssertGreaterThan(grouped.count, 1, "long lines must split on characters")
    }

    func testNothingIsLostWhenAGroupIsSplit() {
        let blocks = paragraph(lines: 30)
        let grouped = BlockGrouping.group(blocks)

        let originalWords = blocks.flatMap { $0.text.split(separator: " ") }.count
        let groupedWords = grouped.flatMap { $0.text.split(separator: " ") }.count
        XCTAssertEqual(groupedWords, originalWords, "splitting must not drop text")
    }

    func testShortParagraphStillMergesNormally() {
        let grouped = BlockGrouping.group(paragraph(lines: 3))
        XCTAssertEqual(grouped.count, 1, "capping must not stop ordinary merging")
    }

    func testCapIsConfigurable() {
        let options = BlockGrouping.Options(maxLinesPerGroup: 2)
        let grouped = BlockGrouping.group(paragraph(lines: 6), options: options)
        XCTAssertGreaterThanOrEqual(grouped.count, 3)
        for group in grouped {
            XCTAssertLessThanOrEqual(group.text.split(separator: " ").count, 2 * 3)
        }
    }
}
