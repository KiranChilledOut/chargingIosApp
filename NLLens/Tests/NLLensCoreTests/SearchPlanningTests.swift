import XCTest
@testable import NLLensCore

/// The bug this exists to prevent, seen on a real device: asked "what is the
/// average rate?" about a Dutch energy contract, the app sent that sentence to
/// Tavily verbatim. With no topic in it, the engine matched on the country
/// alone and returned Dutch travel and entry requirements — and the answer had
/// to admit it still could not give a figure.
final class SearchQueryBuilderTests: XCTestCase {

    private let screen = """
    Budget Thuis — Mijn contract
    Stroom 0,25970 per kWh
    Gas 1,18 per m3
    Vaste leveringskosten 5,99 per maand
    """

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let day = Date(timeIntervalSince1970: 1_774_000_000)  // 2026

    func testAnAnaphoricFollowUpBorrowsTheScreensTopic() {
        let query = SearchQueryBuilder.fallbackQuery(
            question: "is that a good rate?",
            screenText: screen,
            visualReading: "An energy contract overview",
            now: day, calendar: calendar
        )

        XCTAssertTrue(query.lowercased().contains("stroom") || query.lowercased().contains("kwh"),
                      "the topic has to come from somewhere: \(query)")
        XCTAssertTrue(query.contains("Budget"), "the provider is the sharpest term available")
        XCTAssertTrue(query.contains("Nederland"))
        XCTAssertTrue(query.contains("2026"), "a rate without a year matches any year")
    }

    func testASelfContainedQuestionIsNotDilutedWithTheWholeScreen() {
        let query = SearchQueryBuilder.fallbackQuery(
            question: "average electricity tariff per kWh in the Netherlands",
            screenText: screen,
            now: day, calendar: calendar
        )
        XCTAssertFalse(query.contains("Budget"), "no need to staple the contract to it")
        XCTAssertFalse(query.contains("Nederland"), "it already says Netherlands")
        XCTAssertTrue(query.contains("2026"))
    }

    func testPlaceholdersNeverReachTheSearchEngine() {
        let query = SearchQueryBuilder.fallbackQuery(
            question: "is [[R1]] normal for [[R2]]?",
            screenText: screen, now: day, calendar: calendar
        )
        XCTAssertFalse(query.contains("[[R"))
    }

    func testTopicDetection() {
        XCTAssertFalse(SearchQueryBuilder.carriesItsOwnTopic("is that good?"))
        XCTAssertFalse(SearchQueryBuilder.carriesItsOwnTopic("what about the other one then"))
        XCTAssertTrue(
            SearchQueryBuilder.carriesItsOwnTopic("what is the average energy tariff here")
        )
    }

    func testAnchorsPreferNamesThenDomainWords() {
        let anchors = SearchQueryBuilder.topicAnchors(in: screen)
        XCTAssertTrue(anchors.contains("Budget"))
        XCTAssertTrue(anchors.contains("kwh") || anchors.contains("stroom"))
        XCTAssertLessThanOrEqual(anchors.count, 6)
    }

    func testAcceptabilityRejectsWhatAModelSometimesReturnsInstead() {
        XCTAssertFalse(SearchQueryBuilder.isAcceptable("search"))
        XCTAssertFalse(SearchQueryBuilder.isAcceptable(""))
        XCTAssertFalse(
            SearchQueryBuilder.isAcceptable("tarief [[R1]] 2026"),
            "a placeholder must never reach the engine"
        )
        XCTAssertTrue(
            SearchQueryBuilder.isAcceptable("gemiddelde stroomprijs kWh Nederland 2026")
        )
    }
}

final class SearchPlanParsingTests: XCTestCase {

    func testAPlanIsReadFromTheModelReply() {
        let plan = TranslationPipeline.parsePlan(
            #"{"query":"gemiddelde stroomprijs kWh Nederland 2026","needs_search":true,"reason":"rates change yearly"}"#
        )
        XCTAssertEqual(plan?.query, "gemiddelde stroomprijs kWh Nederland 2026")
        XCTAssertEqual(plan?.needsSearch, true)
        XCTAssertEqual(plan?.reason, "rates change yearly")
        XCTAssertTrue(plan?.isUsable ?? false)
    }

    func testAPlanSurvivesTheFencesModelsWrapJSONIn() {
        let plan = TranslationPipeline.parsePlan(
            "Here you go:\n```json\n{\"query\":\"huurtoeslag grens 2026\",\"needs_search\":true,\"reason\":\"\"}\n```"
        )
        XCTAssertEqual(plan?.query, "huurtoeslag grens 2026")
    }

    /// A planner that forgot the field must not silently turn search off.
    func testAMissingNeedsSearchMeansYes() {
        let plan = TranslationPipeline.parsePlan(#"{"query":"iets in het nederlands"}"#)
        XCTAssertEqual(plan?.needsSearch, true)
    }

    func testTranslationQuestionsCanDeclineTheLookup() {
        let plan = TranslationPipeline.parsePlan(
            #"{"query":"","needs_search":false,"reason":"just translating a word"}"#
        )
        XCTAssertEqual(plan?.needsSearch, false)
        XCTAssertFalse(plan?.isUsable ?? true)
        XCTAssertEqual(SearchStatus.notNeeded("just translating a word").note,
                       "No lookup needed — just translating a word")
    }

    func testNonsenseYieldsNoPlanSoTheFallbackIsUsed() {
        XCTAssertNil(TranslationPipeline.parsePlan("I'm sorry, I can't do that."))
    }
}

final class MemoryFactParsingTests: XCTestCase {

    func testFactsAreReadFromTheModelReply() {
        let facts = TranslationPipeline.parseFacts(
            #"{"facts":[{"key":"energy-provider","label":"Energy provider","value":"Budget Thuis"},"#
            + #"{"key":"energy-tariff","label":"Electricity","value":"€0.25970 per kWh"}]}"#,
            source: "contract screen"
        )
        XCTAssertEqual(facts.map(\.key), ["energy-provider", "energy-tariff"])
        XCTAssertEqual(facts.first?.source, "contract screen")
    }

    func testAnEmptyListIsTheNormalAnswer() {
        XCTAssertTrue(TranslationPipeline.parseFacts(#"{"facts":[]}"#).isEmpty)
    }

    func testFactsCarryingRedactedValuesAreDropped() {
        let facts = TranslationPipeline.parseFacts(
            #"{"facts":[{"key":"iban","label":"Account","value":"[[R1]]"},"#
            + #"{"key":"city","label":"City","value":"Groningen"}]}"#
        )
        XCTAssertEqual(facts.map(\.key), ["city"])
    }

    func testGarbageYieldsNothingRatherThanThrowing() {
        XCTAssertTrue(TranslationPipeline.parseFacts("not json at all").isEmpty)
    }
}
