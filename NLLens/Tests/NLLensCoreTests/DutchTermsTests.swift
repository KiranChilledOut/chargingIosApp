import XCTest
@testable import NLLensCore

final class DutchTermsTests: XCTestCase {

    func testFindsASingleWordTerm() {
        let matches = DutchTermIndex.matches(in: "Uw zorgverzekering is verlengd")
        XCTAssertTrue(matches.contains { $0.term == "zorgverzekering" })
    }

    func testFindsAMultiWordTerm() {
        let matches = DutchTermIndex.matches(in: "U betaalt eerst uw eigen risico")
        XCTAssertTrue(matches.contains { $0.term == "eigen risico" })
    }

    func testMatchesAnAlias() {
        let matches = DutchTermIndex.matches(in: "Vul uw burgerservicenummer in")
        XCTAssertTrue(matches.contains { $0.term == "BSN" })
    }

    func testHyphenAndSpaceFormsMatchEqually() {
        let hyphen = DutchTermIndex.matches(in: "De WOZ-waarde van uw woning")
        let spaced = DutchTermIndex.matches(in: "De WOZ waarde van uw woning")
        XCTAssertTrue(hyphen.contains { $0.term == "WOZ-waarde" })
        XCTAssertTrue(spaced.contains { $0.term == "WOZ-waarde" })
    }

    func testCaseInsensitive() {
        XCTAssertTrue(
            DutchTermIndex.matches(in: "DIGID INLOGGEN").contains { $0.term == "DigiD" }
        )
    }

    func testDoesNotMatchInsideALongerWord() {
        // "borg" sits inside "borgstelling"; flagging it would be worse than
        // staying quiet, since Dutch compounds constantly do this.
        let matches = DutchTermIndex.matches(in: "Een borgstelling van de bank")
        XCTAssertFalse(matches.contains { $0.term == "borg" })
    }

    func testStandaloneWordStillMatches() {
        let matches = DutchTermIndex.matches(in: "De borg bedraagt twee maanden")
        XCTAssertTrue(matches.contains { $0.term == "borg" })
    }

    func testLongerMatchIsRankedFirst() {
        let matches = DutchTermIndex.matches(in: "Uw voorlopige aanslag inkomstenbelasting")
        XCTAssertEqual(matches.first?.term, "voorlopige aanslag")
    }

    func testNoMatchesOnUnrelatedText() {
        XCTAssertTrue(DutchTermIndex.matches(in: "Hallo wereld").isEmpty)
    }

    func testEmptyTextIsSafe() {
        XCTAssertTrue(DutchTermIndex.matches(in: "").isEmpty)
    }

    func testLimitIsRespected() {
        let dense = DutchTermIndex.all.map(\.term).joined(separator: " ")
        XCTAssertLessThanOrEqual(DutchTermIndex.matches(in: dense, limit: 5).count, 5)
    }

    func testGroundingIsEmptyWhenNothingMatched() {
        // Costs nothing on screens that need no help.
        XCTAssertTrue(DutchTermIndex.grounding(for: "Hallo wereld").isEmpty)
    }

    func testGroundingCarriesMeaningNotJustTranslation() {
        let grounding = DutchTermIndex.grounding(for: "uw eigen risico voor dit jaar")
        XCTAssertTrue(grounding.contains("eigen risico"))
        XCTAssertTrue(
            grounding.lowercased().contains("deductible"),
            "grounding must explain what it is, not just translate it"
        )
    }

    func testLookupByName() {
        XCTAssertEqual(DutchTermIndex.term(named: "burgerservicenummer")?.term, "BSN")
        XCTAssertNil(DutchTermIndex.term(named: "nonsense"))
    }

    // MARK: - Index hygiene

    func testNoDuplicateTerms() {
        let terms = DutchTermIndex.all.map { $0.term.lowercased() }
        XCTAssertEqual(Set(terms).count, terms.count, "duplicate term in the index")
    }

    func testEveryEntryIsComplete() {
        for entry in DutchTermIndex.all {
            XCTAssertFalse(entry.term.isEmpty)
            XCTAssertFalse(entry.literal.isEmpty, "\(entry.term) has no literal")
            XCTAssertFalse(entry.meaning.isEmpty, "\(entry.term) has no meaning")
            XCTAssertGreaterThan(
                entry.meaning.count, entry.literal.count,
                "\(entry.term): the meaning should say more than the translation"
            )
        }
    }

    func testMeaningsCarryNoHardCodedAmounts() {
        // Rates and thresholds change yearly; a confidently stale number is
        // worse than none.
        for entry in DutchTermIndex.all {
            XCTAssertFalse(
                entry.meaning.contains("€"),
                "\(entry.term) hard-codes an amount that will go stale"
            )
        }
    }

    func testEveryCategoryIsRepresented() {
        let used = Set(DutchTermIndex.all.map(\.category))
        XCTAssertEqual(used.count, DutchTerm.Category.allCases.count)
    }

    // MARK: - Tokenizer

    func testTokenizer() {
        XCTAssertEqual(DutchTermIndex.tokens(of: "WOZ-waarde!"), ["woz", "waarde"])
        XCTAssertEqual(DutchTermIndex.tokens(of: "  spaced   out "), ["spaced", "out"])
        XCTAssertTrue(DutchTermIndex.tokens(of: "!!!").isEmpty)
    }

    func testContainsRun() {
        XCTAssertTrue(DutchTermIndex.contains(["a", "b", "c"], ["b", "c"]))
        XCTAssertFalse(DutchTermIndex.contains(["a", "b", "c"], ["a", "c"]))
        XCTAssertFalse(DutchTermIndex.contains(["a"], ["a", "b"]))
        XCTAssertFalse(DutchTermIndex.contains(["a"], []))
    }
}
