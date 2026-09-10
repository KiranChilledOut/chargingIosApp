import XCTest
@testable import NLLensCore

private func screen(_ lines: [String]) -> [TranslatedBlock] {
    lines.enumerated().map { index, line in
        TranslatedBlock(
            id: index,
            sourceText: line,
            translatedText: "EN:\(line)",
            box: BoundingBox(x: 0, y: Double(index) * 0.1, width: 1, height: 0.08)
        )
    }
}

private func sources(_ document: StitchedDocument) -> [String] {
    document.blocks.map(\.sourceText)
}

final class ScreenStitchingTests: XCTestCase {

    func testSingleScreenPassesThrough() {
        let result = ScreenStitching.merge([screen(["een", "twee"])])
        XCTAssertEqual(sources(result), ["een", "twee"])
        XCTAssertEqual(result.duplicatesRemoved, 0)
        XCTAssertEqual(result.screenCount, 1)
    }

    func testOverlappingScrollCapturesAreJoinedOnce() {
        // The realistic case: the user scrolls about two-thirds of a screen,
        // so the last lines of one capture are the first of the next.
        let a = screen(["regel 1", "regel 2", "regel 3", "regel 4"])
        let b = screen(["regel 3", "regel 4", "regel 5", "regel 6"])

        let result = ScreenStitching.merge([a, b])
        XCTAssertEqual(
            sources(result),
            ["regel 1", "regel 2", "regel 3", "regel 4", "regel 5", "regel 6"]
        )
        XCTAssertEqual(result.duplicatesRemoved, 2)
    }

    func testNonOverlappingCapturesAreConcatenated() {
        let result = ScreenStitching.merge([screen(["a", "b"]), screen(["c", "d"])])
        XCTAssertEqual(sources(result), ["a", "b", "c", "d"])
        XCTAssertEqual(result.duplicatesRemoved, 0)
    }

    func testIdenticalCaptureIsFullyAbsorbed() {
        // User pressed the shortcut twice without scrolling.
        let a = screen(["kop", "tekst"])
        let result = ScreenStitching.merge([a, a])
        XCTAssertEqual(sources(result), ["kop", "tekst"])
        XCTAssertEqual(result.duplicatesRemoved, 2)
    }

    func testThreeCapturesChainCorrectly() {
        let a = screen(["1", "2", "3"])
        let b = screen(["3", "4", "5"])
        let c = screen(["5", "6", "7"])
        let result = ScreenStitching.merge([a, b, c])
        XCTAssertEqual(sources(result), ["1", "2", "3", "4", "5", "6", "7"])
        XCTAssertEqual(result.screenCount, 3)
    }

    func testLongerOverlapWinsOverIncidentalSingleLineMatch() {
        // Both captures contain "Annuleren", but the real overlap is the two
        // trailing lines. Matching the longest run avoids losing a line.
        let a = screen(["Annuleren", "alpha", "beta", "gamma"])
        let b = screen(["beta", "gamma", "delta"])
        let result = ScreenStitching.merge([a, b])
        XCTAssertEqual(
            sources(result),
            ["Annuleren", "alpha", "beta", "gamma", "delta"]
        )
    }

    func testOverlapMatchingIgnoresOCRSpacingAndQuoteNoise() {
        // The same on-screen line, recognized slightly differently between
        // captures, must still be treated as the overlap.
        let a = screen(["Uw betaling is  gelukt", "Bedankt"])
        let b = screen(["Uw betaling is gelukt", "Bedankt", "Volgende"])
        let result = ScreenStitching.merge([a, b])
        XCTAssertEqual(result.duplicatesRemoved, 2)
        XCTAssertEqual(sources(result).count, 3)
    }

    func testEmptyScreensAreSkipped() {
        let result = ScreenStitching.merge([[], screen(["a"]), []])
        XCTAssertEqual(sources(result), ["a"])
        XCTAssertEqual(result.screenCount, 1)
    }

    func testAllEmptyGivesEmptyDocument() {
        let result = ScreenStitching.merge([[], []])
        XCTAssertTrue(result.blocks.isEmpty)
    }

    func testNoInputGivesEmptyDocument() {
        XCTAssertTrue(ScreenStitching.merge([]).blocks.isEmpty)
    }

    func testIDsAreRenumberedUniquelyAcrossScreens() {
        // Each capture numbers from zero, so ids collide unless reassigned —
        // and SwiftUI's ForEach would drop rows if they did.
        let result = ScreenStitching.merge([screen(["a", "b"]), screen(["c", "d"])])
        XCTAssertEqual(result.blocks.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(Set(result.blocks.map(\.id)).count, result.blocks.count)
    }

    func testTranslationsAreCarriedThrough() {
        let result = ScreenStitching.merge([screen(["een"]), screen(["twee"])])
        XCTAssertEqual(result.blocks.map(\.translatedText), ["EN:een", "EN:twee"])
    }

    // MARK: - overlapLength

    func testOverlapLengthBasics() {
        XCTAssertEqual(ScreenStitching.overlapLength(["a", "b", "c"], ["b", "c", "d"]), 2)
        XCTAssertEqual(ScreenStitching.overlapLength(["a"], ["a"]), 1)
        XCTAssertEqual(ScreenStitching.overlapLength(["a", "b"], ["c", "d"]), 0)
        XCTAssertEqual(ScreenStitching.overlapLength([], ["a"]), 0)
        XCTAssertEqual(ScreenStitching.overlapLength(["a"], []), 0)
    }

    func testOverlapLengthPrefersLongestRun() {
        // Both k=1 and k=3 align here ("q" ends a and starts b). Returning 3
        // is what stops a repeated line being emitted twice.
        XCTAssertEqual(
            ScreenStitching.overlapLength(["q", "p", "q"], ["q", "p", "q", "r"]),
            3
        )
        XCTAssertEqual(
            ScreenStitching.overlapLength(["z", "p", "q", "x"], ["p", "q", "x", "y"]),
            3
        )
    }

    func testOverlapCannotExceedEitherInput() {
        let long = ["a", "b", "c", "d", "e"]
        let short = ["d", "e"]
        XCTAssertEqual(ScreenStitching.overlapLength(long, short), 2)
        XCTAssertLessThanOrEqual(
            ScreenStitching.overlapLength(long, short), short.count
        )
    }
}
