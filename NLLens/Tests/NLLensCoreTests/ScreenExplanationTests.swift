import XCTest
@testable import NLLensCore

/// A JSON Schema is a request, not a guarantee — especially from vision
/// models. Every shape here would throw under synthesized decoding, and each
/// one is a perfectly usable reply the user would otherwise see as an error.
final class ScreenExplanationTests: XCTestCase {

    private func decode(_ raw: String) throws -> ScreenExplanation {
        try JSONExtraction.decode(ScreenExplanation.self, from: raw)
    }

    func testCanonicalShape() throws {
        let result = try decode("""
        {"summary":"Payment failed","actions":["Try another card"],"warnings":["Renews monthly"]}
        """)
        XCTAssertEqual(result.summary, "Payment failed")
        XCTAssertEqual(result.actions, ["Try another card"])
        XCTAssertEqual(result.warnings, ["Renews monthly"])
    }

    func testBareStringInsteadOfArray() throws {
        let result = try decode("""
        {"summary":"Login screen","actions":"Enter your DigiD","warnings":"Session expires in 5 minutes"}
        """)
        XCTAssertEqual(result.actions, ["Enter your DigiD"])
        XCTAssertEqual(result.warnings, ["Session expires in 5 minutes"])
    }

    func testMissingSectionsBecomeEmpty() throws {
        let result = try decode(#"{"summary":"A form"}"#)
        XCTAssertEqual(result.summary, "A form")
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testObjectsWithTextKey() throws {
        let result = try decode("""
        {"summary":"Form","actions":[{"text":"Fill in your BSN"},{"text":"Press Verzenden"}],"warnings":[]}
        """)
        XCTAssertEqual(result.actions, ["Fill in your BSN", "Press Verzenden"])
    }

    func testObjectsWithAlternateKeys() throws {
        let result = try decode("""
        {"summary":"S","actions":[{"action":"Tap Akkoord"}],"warnings":[{"warning":"Pre-ticked box"}]}
        """)
        XCTAssertEqual(result.actions, ["Tap Akkoord"])
        XCTAssertEqual(result.warnings, ["Pre-ticked box"])
    }

    func testAlternateSummaryKeys() throws {
        XCTAssertEqual(try decode(#"{"title":"Insurance renewal"}"#).summary, "Insurance renewal")
        XCTAssertEqual(try decode(#"{"explanation":"A payment screen"}"#).summary, "A payment screen")
    }

    func testSummaryArrivingAsArray() throws {
        let result = try decode(#"{"summary":["Payment screen.","Card was declined."]}"#)
        XCTAssertEqual(result.summary, "Payment screen. Card was declined.")
    }

    func testEmptyStringsAreDropped() throws {
        let result = try decode(#"{"summary":"S","actions":["","Do this",""],"warnings":[]}"#)
        XCTAssertEqual(result.actions, ["Do this"])
    }

    func testFencedAndPaddedResponseStillDecodes() throws {
        let result = try decode("""
        Here's what that screen says:
        ```json
        {"summary":"Tax return","actions":["Check the amount"],"warnings":["Deadline 1 May"]}
        ```
        """)
        XCTAssertEqual(result.summary, "Tax return")
        XCTAssertEqual(result.warnings, ["Deadline 1 May"])
    }

    func testWhollyEmptyReplyIsFlagged() throws {
        let result = try decode("{}")
        XCTAssertTrue(result.isEmpty, "caller should say so rather than show a blank card")
    }

    func testNonEmptyIsNotFlagged() throws {
        XCTAssertFalse(try decode(#"{"summary":"x"}"#).isEmpty)
    }

    func testRoundTripsThroughEncoding() throws {
        // Explanations are persisted with the screen, so encode must work
        // even though the decoder accepts keys the encoder never writes.
        let original = ScreenExplanation(
            summary: "S", actions: ["a"], warnings: ["w"]
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ScreenExplanation.self, from: data)
        XCTAssertEqual(restored, original)

        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("title"), "alternate keys must not be written")
        XCTAssertFalse(json.contains("explanation"))
    }
}
