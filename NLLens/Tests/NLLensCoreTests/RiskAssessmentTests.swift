import XCTest
@testable import NLLensCore

final class RiskAssessmentTests: XCTestCase {

    private func decode(_ raw: String) throws -> RiskAssessment {
        try JSONExtraction.decode(RiskAssessment.self, from: raw)
    }

    func testCanonicalDangerShape() throws {
        let result = try decode("""
        {"level":"danger","headline":"This is not a real DigiD page",
         "signals":["Asks for your DigiD password","Domain is not a .nl government domain"],
         "advice":"Close it and go to digid.nl yourself."}
        """)
        XCTAssertEqual(result.level, .danger)
        XCTAssertEqual(result.signals.count, 2)
        XCTAssertTrue(result.isWorthSurfacing)
    }

    func testOrdinaryScreenStaysSilent() throws {
        let result = try decode(#"{"level":"fine","headline":"Looks like a normal bill","signals":[],"advice":""}"#)
        XCTAssertFalse(
            result.isWorthSurfacing,
            "a badge on every screen is a badge nobody reads"
        )
    }

    func testLevelSynonymsMapCorrectly() {
        XCTAssertEqual(RiskAssessment.Level.parse("safe"), .fine)
        XCTAssertEqual(RiskAssessment.Level.parse("OK"), .fine)
        XCTAssertEqual(RiskAssessment.Level.parse("legitimate"), .fine)
        XCTAssertEqual(RiskAssessment.Level.parse("high"), .danger)
        XCTAssertEqual(RiskAssessment.Level.parse("phishing"), .danger)
        XCTAssertEqual(RiskAssessment.Level.parse("medium"), .caution)
        XCTAssertEqual(RiskAssessment.Level.parse("suspicious"), .caution)
    }

    func testUnknownLevelFailsTowardCautionNotSafety() {
        // If the model said something we do not recognise, that is not
        // evidence the screen is safe.
        XCTAssertEqual(RiskAssessment.Level.parse("bananas"), .caution)
        XCTAssertEqual(RiskAssessment.Level.parse(nil), .caution)
        XCTAssertEqual(RiskAssessment.Level.parse(""), .caution)
    }

    func testMissingLevelIsCautionNotFine() throws {
        let result = try decode(#"{"headline":"Something odd here"}"#)
        XCTAssertEqual(result.level, .caution)
    }

    func testAlternateKeys() throws {
        let result = try decode("""
        {"risk":"high","summary":"Fake bank page","reasons":["Asks for your PIN"],
         "recommendation":"Do not enter anything."}
        """)
        XCTAssertEqual(result.level, .danger)
        XCTAssertEqual(result.headline, "Fake bank page")
        XCTAssertEqual(result.signals, ["Asks for your PIN"])
        XCTAssertEqual(result.advice, "Do not enter anything.")
    }

    func testSignalsAsBareString() throws {
        let result = try decode(#"{"level":"caution","headline":"h","signals":"Urgent deadline"}"#)
        XCTAssertEqual(result.signals, ["Urgent deadline"])
    }

    func testSignalsAsObjects() throws {
        let result = try decode("""
        {"level":"danger","headline":"h","signals":[{"signal":"Asks for a code"},{"text":"Threatens closure"}]}
        """)
        XCTAssertEqual(result.signals, ["Asks for a code", "Threatens closure"])
    }

    func testFencedResponseDecodes() throws {
        let result = try decode("""
        ```json
        {"level":"fine","headline":"Normal login","signals":[],"advice":""}
        ```
        """)
        XCTAssertEqual(result.level, .fine)
    }

    func testRoundTripsThroughEncoding() throws {
        let original = RiskAssessment(
            level: .caution, headline: "h", signals: ["s"], advice: "a"
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(RiskAssessment.self, from: data), original)

        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"risk\""), "alternate keys are read, never written")
    }
}
