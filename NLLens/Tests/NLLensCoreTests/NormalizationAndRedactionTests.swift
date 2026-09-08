import XCTest
@testable import NLLensCore

final class NormalizationTests: XCTestCase {

    func testWhitespaceCollapse() {
        XCTAssertEqual(
            TextNormalization.collapseWhitespace("  Mijn   \n gegevens  "),
            "Mijn gegevens"
        )
    }

    func testCurlyQuotesAndDashesFold() {
        let a = TextNormalization.cacheKey("Mijn \u{2018}account\u{2019}")
        let b = TextNormalization.cacheKey("Mijn 'account'")
        XCTAssertEqual(a, b, "OCR punctuation variation must not miss the cache")
    }

    func testZeroWidthCharactersIgnored() {
        let a = TextNormalization.cacheKey("Open\u{200B}en")
        let b = TextNormalization.cacheKey("Openen")
        XCTAssertEqual(a, b)
    }

    func testHashIsStableAcrossCalls() {
        // Must not use Swift's per-process-seeded Hasher.
        XCTAssertEqual(
            TextNormalization.stableHash("Instellingen"),
            TextNormalization.stableHash("Instellingen")
        )
        XCTAssertNotEqual(
            TextNormalization.stableHash("Instellingen"),
            TextNormalization.stableHash("Instellingem")
        )
    }

    func testKnownHashValueDoesNotDrift() {
        // Pins the algorithm: changing it silently invalidates every cache.
        XCTAssertEqual(TextNormalization.stableHash(""), 0xcbf2_9ce4_8422_2325)
    }

    func testIsTranslatable() {
        XCTAssertTrue(TextNormalization.isTranslatable("Openen"))
        XCTAssertTrue(TextNormalization.isTranslatable("Bedrag: 24,95"))
        XCTAssertFalse(TextNormalization.isTranslatable("€ 24,95"))
        XCTAssertFalse(TextNormalization.isTranslatable("12:45"))
        XCTAssertFalse(TextNormalization.isTranslatable(""))
        XCTAssertFalse(TextNormalization.isTranslatable("—"))
    }
}

final class RedactionIntegrationTests: XCTestCase {

    func testIBANIsMaskedAndRestored() {
        let (masked, map) = Redactor.redact(text: "Rekening NL91ABNA0417164300 saldo")
        XCTAssertFalse(masked.contains("NL91ABNA0417164300"))
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.restore(in: masked), "Rekening NL91ABNA0417164300 saldo")
    }

    func testSameValueTwiceSharesOnePlaceholder() {
        let (masked, map) = Redactor.redact(
            text: "a@b.com en nogmaals a@b.com"
        )
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(masked.components(separatedBy: "[[R1]]").count - 1, 2)
    }

    func testRestoreToleratesReformattedPlaceholder() {
        let (_, map) = Redactor.redact(text: "mail: a@b.com")
        // Models sometimes add spaces or drop the R.
        XCTAssertEqual(map.restore(in: "Email: [[ R1 ]]"), "Email: a@b.com")
        XCTAssertEqual(map.restore(in: "Email: [[1]]"), "Email: a@b.com")
    }

    func testUnknownPlaceholderIsLeftVisibleNotDropped() {
        let (_, map) = Redactor.redact(text: "mail: a@b.com")
        // A failure should be visible rather than silently swallowing text.
        XCTAssertEqual(map.restore(in: "Value [[R9]]"), "Value [[R9]]")
    }

    func testNonSensitiveTextIsUntouched() {
        let (masked, map) = Redactor.redact(text: "Openen en annuleren")
        XCTAssertEqual(masked, "Openen en annuleren")
        XCTAssertTrue(map.isEmpty)
    }

    func testOverlappingPatternsPreferLongestMatch() {
        // The card pattern could match a slice of the IBAN's digits.
        let (masked, map) = Redactor.redact(text: "NL91ABNA0417164300")
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.spans.values.first?.kind, .iban)
        XCTAssertEqual(masked, "[[R1]]")
    }

    func testPostcodeOnlyMaskedUnderStrictPolicy() {
        let standard = Redactor.redact(text: "Adres 1012 AB", policy: .standard)
        XCTAssertTrue(standard.map.isEmpty)

        let strict = Redactor.redact(text: "Adres 1012 AB", policy: .strict)
        XCTAssertEqual(strict.map.kindsFound, [.postcode])
    }

    func testNonePolicyDisablesRedaction() {
        let (masked, map) = Redactor.redact(text: "a@b.com", policy: .none)
        XCTAssertEqual(masked, "a@b.com")
        XCTAssertTrue(map.isEmpty)
    }

    func testBlocksSharePlaceholderNamespace() {
        let blocks = [
            TextBlock(id: 0, text: "IBAN NL91ABNA0417164300", box: .init(x: 0, y: 0, width: 1, height: 1)),
            TextBlock(id: 1, text: "Nogmaals NL91ABNA0417164300", box: .init(x: 0, y: 0, width: 1, height: 1)),
        ]
        let (redacted, map) = Redactor.redact(blocks: blocks)
        XCTAssertEqual(map.count, 1, "same IBAN in two blocks is one placeholder")
        XCTAssertTrue(redacted.allSatisfy { $0.text.contains("[[R1]]") })
    }
}
