import XCTest
@testable import NLLensCore

private func block(_ id: Int, _ text: String, height: Double) -> TranslatedBlock {
    TranslatedBlock(
        id: id, sourceText: "nl", translatedText: text,
        box: BoundingBox(x: 0, y: Double(id) * 0.1, width: 1, height: height)
    )
}

final class ArchiveTitleTests: XCTestCase {

    func testPrefersTheHeading() {
        let blocks = [
            block(0, "Some body text here", height: 0.03),
            block(1, "Provisional tax assessment", height: 0.07),
            block(2, "More body text", height: 0.03),
            block(3, "Even more body", height: 0.03),
        ]
        XCTAssertEqual(ArchiveTitle.derive(from: blocks), "Provisional tax assessment")
    }

    func testFallsBackToTheFirstSubstantialLine() {
        let blocks = (0..<4).map { block($0, "Line number \($0) of body text", height: 0.03) }
        XCTAssertEqual(ArchiveTitle.derive(from: blocks), "Line number 0 of body text")
    }

    func testSkipsShortControlLabels() {
        // "OK" names nothing; the archive entry would be unfindable.
        let blocks = [
            block(0, "OK", height: 0.03),
            block(1, "Back", height: 0.03),
            block(2, "Your health insurance renewal", height: 0.03),
            block(3, "Another line of text", height: 0.03),
        ]
        XCTAssertEqual(ArchiveTitle.derive(from: blocks), "Your health insurance renewal")
    }

    func testSkipsNumbersAndPrices() {
        let blocks = [
            block(0, "€ 24,95", height: 0.03),
            block(1, "12:45", height: 0.03),
            block(2, "Payment confirmation page", height: 0.03),
            block(3, "Some other line", height: 0.03),
        ]
        XCTAssertEqual(ArchiveTitle.derive(from: blocks), "Payment confirmation page")
    }

    func testEmptyInput() {
        XCTAssertEqual(ArchiveTitle.derive(from: []), "Untitled screen")
    }

    func testAllUnusableInput() {
        let blocks = [block(0, "€ 5", height: 0.03), block(1, "—", height: 0.03)]
        XCTAssertEqual(ArchiveTitle.derive(from: blocks), "Untitled screen")
    }

    func testLongTitleIsCutOnAWordBoundary() {
        let long = "This is an extremely long heading that will certainly need shortening before it fits"
        let result = ArchiveTitle.shorten(long)
        XCTAssertLessThanOrEqual(result.count, ArchiveTitle.maxLength + 1)
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertFalse(
            result.dropLast().hasSuffix(" "), "should not leave a trailing space"
        )
        XCTAssertTrue(long.hasPrefix(String(result.dropLast())))
    }

    func testShortTitleIsUntouched() {
        XCTAssertEqual(ArchiveTitle.shorten("Short one"), "Short one")
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(ArchiveTitle.shorten("  too   much   space "), "too much space")
    }
}
