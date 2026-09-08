import XCTest
@testable import NLLensCore

final class RedactionChecksumTests: XCTestCase {

    func testValidBSNsPassElfproef() {
        // Hand-computed against weights 9,8,7,6,5,4,3,2,-1.
        XCTAssertTrue(Redactor.isValidBSN("111222333"))
        XCTAssertTrue(Redactor.isValidBSN("123456782"))
    }

    func testInvalidBSNsRejected() {
        XCTAssertFalse(Redactor.isValidBSN("123456789"))
        XCTAssertFalse(Redactor.isValidBSN("000000000"), "all zeros is never a real BSN")
        XCTAssertFalse(Redactor.isValidBSN("12345678"), "too short")
        XCTAssertFalse(Redactor.isValidBSN("1234567890"), "too long")
    }

    func testOrderNumbersAreNotMistakenForBSN() {
        // The reason the checksum exists: most 9-digit runs on screen are
        // order numbers, and masking them would gut the translation.
        let nineDigitRuns = ["100000001", "202512345", "987654321"]
        let flagged = nineDigitRuns.filter { Redactor.isValidBSN($0) }
        XCTAssertTrue(
            flagged.count < nineDigitRuns.count,
            "checksum should reject at least some arbitrary 9-digit runs"
        )
    }

    func testValidIBAN() {
        XCTAssertTrue(Redactor.isValidIBAN("NL91ABNA0417164300"))
        XCTAssertTrue(Redactor.isValidIBAN("NL91 ABNA 0417 1643 00"), "spaced form")
        XCTAssertTrue(Redactor.isValidIBAN("DE89370400440532013000"))
    }

    func testInvalidIBAN() {
        XCTAssertFalse(Redactor.isValidIBAN("NL91ABNA0417164301"), "bad check digits")
        XCTAssertFalse(Redactor.isValidIBAN("NL91"), "too short")
    }

    func testLuhn() {
        XCTAssertTrue(Redactor.isValidLuhn("4111111111111111"))
        XCTAssertTrue(Redactor.isValidLuhn("4539 5787 6362 1486"))
        XCTAssertFalse(Redactor.isValidLuhn("4111111111111112"))
    }
}
