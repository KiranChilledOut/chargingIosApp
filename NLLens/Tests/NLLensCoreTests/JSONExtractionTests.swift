import XCTest
@testable import NLLensCore

private struct Unit: Codable, Equatable {
    let id: Int
    let nl: String
    let en: String
}

final class JSONExtractionTests: XCTestCase {

    private let expected = [
        Unit(id: 1, nl: "Openen", en: "Open"),
        Unit(id: 2, nl: "Annuleren", en: "Cancel"),
    ]

    private func decodeUnits(_ raw: String) throws -> [Unit] {
        try JSONExtraction.decode([Unit].self, from: raw)
    }

    func testCleanJSON() throws {
        let raw = #"[{"id":1,"nl":"Openen","en":"Open"},{"id":2,"nl":"Annuleren","en":"Cancel"}]"#
        XCTAssertEqual(try decodeUnits(raw), expected)
    }

    func testFencedJSON() throws {
        let raw = """
        ```json
        [{"id":1,"nl":"Openen","en":"Open"},{"id":2,"nl":"Annuleren","en":"Cancel"}]
        ```
        """
        XCTAssertEqual(try decodeUnits(raw), expected)
    }

    func testFencedWithoutLanguageTag() throws {
        let raw = """
        ```
        [{"id":1,"nl":"Openen","en":"Open"},{"id":2,"nl":"Annuleren","en":"Cancel"}]
        ```
        """
        XCTAssertEqual(try decodeUnits(raw), expected)
    }

    func testProsePreamble() throws {
        let raw = """
        Sure! Here is the translation you asked for:

        [{"id":1,"nl":"Openen","en":"Open"},{"id":2,"nl":"Annuleren","en":"Cancel"}]
        """
        XCTAssertEqual(try decodeUnits(raw), expected)
    }

    func testProseOnBothSides() throws {
        let raw = """
        Here you go:
        ```json
        [{"id":1,"nl":"Openen","en":"Open"},{"id":2,"nl":"Annuleren","en":"Cancel"}]
        ```
        Let me know if you need anything else!
        """
        XCTAssertEqual(try decodeUnits(raw), expected)
    }

    func testTrailingCommaIsRepaired() throws {
        let raw = """
        [{"id":1,"nl":"Openen","en":"Open"},{"id":2,"nl":"Annuleren","en":"Cancel"},]
        """
        XCTAssertEqual(try decodeUnits(raw), expected)
    }

    func testBracketsInsideStringsDoNotConfuseScanner() throws {
        // A redaction placeholder is literally "[[R1]]", so this is the exact
        // case the app hits on any screen containing an IBAN.
        let raw = #"prefix [{"id":1,"nl":"Rekening [[R1]]","en":"Account [[R1]]"}] suffix"#
        let units = try decodeUnits(raw)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].en, "Account [[R1]]")
    }

    func testEscapedQuotesInsideStrings() throws {
        let raw = #"[{"id":1,"nl":"Klik \"hier\"","en":"Click \"here\""}]"#
        let units = try decodeUnits(raw)
        XCTAssertEqual(units[0].en, #"Click "here""#)
    }

    func testObjectWithNestedArray() throws {
        struct Explanation: Codable, Equatable {
            let summary: String
            let actions: [String]
        }
        let raw = """
        Here's what that screen says:
        ```json
        {"summary": "Payment failed", "actions": ["Retry with another card", "Call the bank"]}
        ```
        """
        let result = try JSONExtraction.decode(Explanation.self, from: raw)
        XCTAssertEqual(result.summary, "Payment failed")
        XCTAssertEqual(result.actions.count, 2)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try decodeUnits("I'm sorry, I can't help with that."))
    }

    func testBalancedScannerStopsAtCorrectBrace() {
        let input = #"noise {"a": {"b": 1}} trailing {"c": 2}"#
        XCTAssertEqual(JSONExtraction.firstBalancedJSON(in: input), #"{"a": {"b": 1}}"#)
    }

    func testRepairLeavesLegitimateCommasAlone() {
        let input = #"{"a": [1, 2, 3], "b": "x, y"}"#
        XCTAssertEqual(JSONExtraction.repairTrailingCommas(input), input)
    }
}
