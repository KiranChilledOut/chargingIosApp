import XCTest
@testable import NLLensCore

private func block(_ id: Int, _ text: String, height: Double) -> TranslatedBlock {
    TranslatedBlock(
        id: id, sourceText: "nl\(id)", translatedText: text,
        box: BoundingBox(x: 0, y: Double(id) * 0.1, width: 1, height: height)
    )
}

final class TypographyHintsTests: XCTestCase {

    func testTallLineIsAHeading() {
        let blocks = [
            block(0, "Titel", height: 0.06),
            block(1, "body one", height: 0.03),
            block(2, "body two", height: 0.03),
            block(3, "body three", height: 0.03),
        ]
        let roles = TypographyHints.roles(for: blocks)
        XCTAssertEqual(roles[0], .heading)
        XCTAssertEqual(roles[1], .body)
        XCTAssertEqual(roles[3], .body)
    }

    func testShortLineIsACaption() {
        let blocks = [
            block(0, "body one", height: 0.03),
            block(1, "body two", height: 0.03),
            block(2, "body three", height: 0.03),
            block(3, "fine print", height: 0.02),
        ]
        XCTAssertEqual(TypographyHints.roles(for: blocks)[3], .caption)
    }

    func testUniformTextGetsNoInventedHierarchy() {
        let blocks = (0..<6).map { block($0, "line \($0)", height: 0.03) }
        let roles = TypographyHints.roles(for: blocks)
        XCTAssertTrue(roles.values.allSatisfy { $0 == .body })
    }

    func testTooFewBlocksToJudge() {
        let blocks = [block(0, "a", height: 0.09), block(1, "b", height: 0.01)]
        let roles = TypographyHints.roles(for: blocks)
        XCTAssertEqual(roles[0], .body, "two samples cannot establish a median")
        XCTAssertEqual(roles[1], .body)
    }

    func testZeroHeightsDoNotDivideByZero() {
        let blocks = (0..<4).map { block($0, "x", height: 0) }
        let roles = TypographyHints.roles(for: blocks)
        XCTAssertEqual(roles.count, 4)
        XCTAssertTrue(roles.values.allSatisfy { $0 == .body })
    }

    func testEveryBlockGetsARole() {
        let blocks = [
            block(0, "Kop", height: 0.07),
            block(1, "tekst", height: 0.03),
            block(2, "tekst", height: 0.03),
            block(3, "klein", height: 0.015),
        ]
        let roles = TypographyHints.roles(for: blocks)
        XCTAssertEqual(Set(roles.keys), Set(blocks.map(\.id)))
    }

    func testPlainTextSeparatesHeadingsWithBlankLine() {
        let blocks = [
            block(0, "body one", height: 0.03),
            block(1, "body two", height: 0.03),
            block(2, "Heading", height: 0.07),
            block(3, "body three", height: 0.03),
        ]
        let text = TypographyHints.plainText(for: blocks)
        XCTAssertTrue(text.contains("body two\n\nHeading"), text)
    }

    func testPlainTextDoesNotLeadWithBlankLine() {
        let blocks = [
            block(0, "Heading", height: 0.07),
            block(1, "body", height: 0.03),
            block(2, "body", height: 0.03),
            block(3, "body", height: 0.03),
        ]
        XCTAssertFalse(TypographyHints.plainText(for: blocks).hasPrefix("\n"))
    }

    func testPlainTextCanIncludeSource() {
        let blocks = [
            block(0, "Open", height: 0.03),
            block(1, "Cancel", height: 0.03),
            block(2, "Save", height: 0.03),
        ]
        let text = TypographyHints.plainText(for: blocks, includingSource: true)
        XCTAssertTrue(text.contains("Open  [nl0]"), text)
    }

    func testPlainTextOmitsSourceWhenUnchanged() {
        // Numbers and brand names pass through untranslated; echoing them as
        // "€ 5  [€ 5]" would be noise.
        let unchanged = TranslatedBlock(
            id: 0, sourceText: "€ 5", translatedText: "€ 5",
            box: BoundingBox(x: 0, y: 0, width: 1, height: 0.03)
        )
        let text = TypographyHints.plainText(for: [unchanged], includingSource: true)
        XCTAssertEqual(text, "€ 5")
    }
}
