import XCTest
@testable import NLLensCore

private let tavilyBody = """
{
  "query": "energy tariff netherlands",
  "answer": "Average Dutch electricity rates in 2026 sit near 0.26 per kWh.",
  "results": [
    {"title": "Energy prices", "url": "https://example.nl/prices",
     "content": "  Rates   for 2026 are around 0.26 per kWh including tax. ", "score": 0.9},
    {"title": "Tariff overview", "url": "https://example.nl/tariffs",
     "content": "Gas stands near 1.40 per cubic metre.", "score": 0.8}
  ]
}
"""

final class TavilyClientTests: XCTestCase {

    private func client(_ transport: MockTransport, key: String = "tvly-test") -> TavilyClient {
        TavilyClient(apiKey: key, transport: transport)
    }

    func testSendsBearerHeaderNotABodyKey() async throws {
        // Tavily deprecated the body `api_key` and newer keys reject it. Get
        // this wrong and it fails as a bare auth error with nothing pointing
        // at the cause.
        let transport = MockTransport(stubs: [.json(tavilyBody)])
        _ = try await client(transport).search("energy tariff netherlands")

        XCTAssertEqual(
            transport.requests.first?.headers["Authorization"], "Bearer tvly-test"
        )
        XCTAssertFalse(
            transport.recordedBodies().joined().contains("api_key"),
            "the key must not travel in the body"
        )
    }

    func testPostsToTheSearchEndpoint() async throws {
        let transport = MockTransport(stubs: [.json(tavilyBody)])
        _ = try await client(transport).search("x")

        XCTAssertEqual(transport.requests.first?.method, "POST")
        XCTAssertEqual(
            transport.requests.first?.url.absoluteString, "https://api.tavily.com/search"
        )
    }

    func testParsesAnswerAndResults() async throws {
        let transport = MockTransport(stubs: [.json(tavilyBody)])
        let response = try await client(transport).search("energy tariff netherlands")

        XCTAssertTrue(response.answer.contains("0.26"))
        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(response.results[0].url, "https://example.nl/prices")
        XCTAssertEqual(
            response.results[0].snippet,
            "Rates for 2026 are around 0.26 per kWh including tax.",
            "whitespace should be collapsed"
        )
    }

    func testResultsWithoutAUrlAreDropped() throws {
        let body = Data(#"{"results":[{"title":"No link","content":"x"},{"url":"https://a.nl","title":"Good","content":"y"}]}"#.utf8)
        let response = try TavilyClient.parse(body, query: "q")
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].url, "https://a.nl")
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let transport = MockTransport(stubs: [])
        do {
            _ = try await client(transport, key: "  ").search("x")
            XCTFail("expected missingAPIKey")
        } catch let error as WebSearchError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testBlankQueryDoesNotCallOut() async throws {
        let transport = MockTransport(stubs: [])
        let response = try await client(transport).search("   ")
        XCTAssertTrue(response.isEmpty)
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testStatusMapping() {
        XCTAssertEqual(TavilyClient.mapStatus(401), .unauthorized)
        XCTAssertEqual(TavilyClient.mapStatus(429), .rateLimited)
        XCTAssertEqual(TavilyClient.mapStatus(500), .serverError(status: 500))
    }

    func testUnauthorizedSurfaces() async {
        let transport = MockTransport(stubs: [.json("{}", status: 401)])
        do {
            _ = try await client(transport).search("x")
            XCTFail("expected unauthorized")
        } catch let error as WebSearchError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testLongSnippetsAreCondensedOnAWordBoundary() {
        let long = String(repeating: "woord ", count: 200)
        let condensed = TavilyClient.condense(long, limit: 60)
        XCTAssertLessThanOrEqual(condensed.count, 61)
        XCTAssertTrue(condensed.hasSuffix("…"))
        XCTAssertFalse(condensed.dropLast().hasSuffix(" "))
    }

    // MARK: - Grounding

    func testGroundingIsDatedAndTellsTheModelToPreferIt() {
        let response = WebSearchResponse(
            query: "energy rates",
            answer: "About 0.26 per kWh.",
            results: [.init(title: "T", url: "https://a.nl", snippet: "s")]
        )
        let grounding = response.grounding(
            asOf: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertTrue(grounding.contains("energy rates"))
        XCTAssertTrue(grounding.lowercased().contains("prefer these"))
        XCTAssertTrue(grounding.contains("https://a.nl"))
        XCTAssertTrue(grounding.contains("2026"), "must be dated: \(grounding)")
    }

    func testEmptyResponseGroundsNothing() {
        XCTAssertTrue(WebSearchResponse(query: "q").grounding().isEmpty)
    }

    // MARK: - Query building

    func testRedactionPlaceholdersAreStrippedFromTheQuery() {
        // "[[R1]]" means nothing to a search engine and would skew the results.
        let query = TranslationPipeline.searchQuery(
            from: "Is [[R1]] a good rate for [[R2]] in Netherlands?"
        )
        XCTAssertFalse(query.contains("[[R"))
        XCTAssertEqual(query, "Is a good rate for in Netherlands?")
    }

    func testOrdinaryQuestionsPassThrough() {
        XCTAssertEqual(
            TranslationPipeline.searchQuery(from: "  Is this a good deal  in Netherlands ? "),
            "Is this a good deal in Netherlands ?"
        )
    }
}

/// The failure this exists to prevent: a model politely explaining that it
/// cannot search is indistinguishable from a search that ran and found
/// nothing. The status is what tells them apart.
final class SearchStatusTests: XCTestCase {

    private func pipeline(
        _ transport: MockTransport,
        searchTransport: MockTransport? = nil,
        searchKey: String = "tvly-test",
        settings: AppSettings = .default
    ) -> TranslationPipeline {
        TranslationPipeline(
            client: .test(transport: transport),
            cache: nil,
            settings: settings,
            textModel: "configured/model",
            search: searchTransport.map {
                TavilyClient(apiKey: searchKey, transport: $0)
            }
        )
    }

    private var conversation: ScreenConversation {
        var c = ScreenConversation(screenText: "Energy contract")
        c.append(role: .user, text: "Is this a good rate?")
        return c
    }

    private let searchBody = #"{"answer":"About 0.26 per kWh.","results":[{"url":"https://a.nl","title":"Rates","content":"c"}]}"#

    func testSuccessReportsHowManyResults() async throws {
        let answer = try await pipeline(
            MockTransport(completion: "ok"),
            searchTransport: MockTransport(stubs: [.json(searchBody)])
        ).answer(in: conversation)

        XCTAssertEqual(answer.searchStatus, .searched(count: 1))
        XCTAssertTrue(answer.searchStatus.didSearch)
        XCTAssertEqual(answer.sources.count, 1)
    }

    func testNoKeyReportsUnavailableRatherThanSilence() async throws {
        let answer = try await pipeline(MockTransport(completion: "ok")).answer(in: conversation)

        XCTAssertEqual(answer.searchStatus, .unavailable)
        XCTAssertEqual(
            answer.searchStatus.note, "No Tavily key — answered from the screen only"
        )
    }

    func testFailureIsReportedButStillAnswers() async throws {
        let answer = try await pipeline(
            MockTransport(completion: "answered anyway"),
            searchTransport: MockTransport(stubs: [.json("{}", status: 401)])
        ).answer(in: conversation)

        XCTAssertEqual(answer.text, "answered anyway", "a failed search must not block the answer")
        guard case .failed(let reason) = answer.searchStatus else {
            return XCTFail("expected failed, got \(answer.searchStatus)")
        }
        XCTAssertTrue(reason.contains("rejected"), reason)
    }

    func testSettingOffSkipsTheSearch() async throws {
        var settings = AppSettings.default
        settings.webSearchEnabled = false
        let searchTransport = MockTransport(stubs: [.json(searchBody)])

        let answer = try await pipeline(
            MockTransport(completion: "ok"),
            searchTransport: searchTransport, settings: settings
        ).answer(in: conversation)

        XCTAssertEqual(answer.searchStatus, .skipped)
        XCTAssertEqual(searchTransport.requestCount, 0)
    }

    func testForceOverridesTheSettingBeingOff() async throws {
        // The globe in the composer: this turn needs current figures.
        var settings = AppSettings.default
        settings.webSearchEnabled = false
        let searchTransport = MockTransport(stubs: [.json(searchBody)])

        let answer = try await pipeline(
            MockTransport(completion: "ok"),
            searchTransport: searchTransport, settings: settings
        ).answer(in: conversation, forceSearch: true)

        XCTAssertTrue(answer.searchStatus.didSearch)
        XCTAssertEqual(searchTransport.requestCount, 1)
    }

    func testForceStillCannotInventAKey() async throws {
        var settings = AppSettings.default
        settings.webSearchEnabled = false

        let answer = try await pipeline(
            MockTransport(completion: "ok"), settings: settings
        ).answer(in: conversation, forceSearch: true)

        XCTAssertEqual(answer.searchStatus, .unavailable)
    }

    func testSearchGroundingReachesTheModel() async throws {
        let transport = MockTransport(completion: "ok")
        _ = try await pipeline(
            transport, searchTransport: MockTransport(stubs: [.json(searchBody)])
        ).answer(in: conversation)

        let body = transport.recordedBodies().joined()
        XCTAssertTrue(body.contains("0.26 per kWh"), "the finding must be in the prompt")
        XCTAssertTrue(body.contains("https://a.nl"))
    }

    // MARK: - Model override

    func testConfiguredModelIsUsedByDefault() async throws {
        let transport = MockTransport(completion: "ok")
        _ = try await pipeline(transport).answer(in: conversation)
        XCTAssertTrue(transport.recordedBodies().joined().contains("configured/model"))
    }

    func testModelCanBeOverriddenPerTurn() async throws {
        let transport = MockTransport(completion: "ok")
        _ = try await pipeline(transport).answer(in: conversation, model: "other/model")

        let body = transport.recordedBodies().joined()
        XCTAssertTrue(body.contains("other/model"))
        XCTAssertFalse(body.contains("configured/model"))
    }

    func testSuccessfulSearchNeedsNoNoteBecauseSourcesShow() {
        XCTAssertNil(SearchStatus.searched(count: 3).note)
        XCTAssertNil(SearchStatus.skipped.note)
        XCTAssertNotNil(SearchStatus.unavailable.note)
        XCTAssertNotNil(SearchStatus.failed("x").note)
    }
}

/// Tavily hands out an MCP URL with the key embedded, so that URL is what gets
/// copied — and pasting it whole returns "Unauthorized: missing or invalid API
/// key", which reads as a bad key rather than the wrong kind of value.
/// Verified against the live endpoint: the URL form is a 401, the bare key a
/// 200.
final class TavilyKeyNormalizationTests: XCTestCase {

    private let key = "tvly-prod-abc123DEF456"

    func testBareKeyIsUnchanged() {
        XCTAssertEqual(TavilyClient.normalizeKey(key), key)
    }

    func testKeyIsExtractedFromTheMCPURL() {
        let url = "https://mcp.tavily.com/mcp/?tavilyApiKey=\(key)"
        XCTAssertEqual(TavilyClient.normalizeKey(url), key)
    }

    func testExtractionIsCaseInsensitiveOnTheParameter() {
        XCTAssertEqual(
            TavilyClient.normalizeKey("https://mcp.tavily.com/mcp/?TavilyApiKey=\(key)"), key
        )
        XCTAssertEqual(
            TavilyClient.normalizeKey("https://api.tavily.com/search?api_key=\(key)"), key
        )
    }

    func testExtractionSurvivesExtraParameters() {
        XCTAssertEqual(
            TavilyClient.normalizeKey(
                "https://mcp.tavily.com/mcp/?foo=1&tavilyApiKey=\(key)&bar=2"
            ),
            key
        )
    }

    func testWhitespaceAndNewlinesAreStripped() {
        XCTAssertEqual(TavilyClient.normalizeKey("  \(key)\n"), key)
    }

    func testSurroundingQuotesAreStripped() {
        // A 401 on the live endpoint, and free with any copy that grabbed a
        // surrounding string literal.
        XCTAssertEqual(TavilyClient.normalizeKey("\"\(key)\""), key)
        XCTAssertEqual(TavilyClient.normalizeKey("'\(key)'"), key)
    }

    func testAURLWithNoKeyParameterIsLeftAlone() {
        let url = "https://mcp.tavily.com/mcp/"
        XCTAssertEqual(TavilyClient.normalizeKey(url), url)
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(TavilyClient.normalizeKey("   "), "")
    }

    func testClientNormalizesOnConstruction() async throws {
        let transport = MockTransport(stubs: [.json(#"{"results":[]}"#)])
        let client = TavilyClient(
            apiKey: "https://mcp.tavily.com/mcp/?tavilyApiKey=\(key)",
            transport: transport
        )
        XCTAssertTrue(client.isUsable)

        _ = try await client.search("anything")
        XCTAssertEqual(
            transport.requests.first?.headers["Authorization"], "Bearer \(key)",
            "the URL must never reach the Authorization header"
        )
    }

    func testAURLWithoutAKeyIsNotUsableAsOne() {
        XCTAssertFalse(TavilyClient.looksLikeKey("https://mcp.tavily.com/mcp/"))
        XCTAssertFalse(TavilyClient.looksLikeKey("hello"))
        XCTAssertTrue(TavilyClient.looksLikeKey(key))
        XCTAssertTrue(
            TavilyClient.looksLikeKey("https://mcp.tavily.com/mcp/?tavilyApiKey=\(key)")
        )
    }

    func testUnauthorizedMessageNamesTheActualMistake() {
        XCTAssertTrue(
            WebSearchError.unauthorized.userMessage.contains("tvly-"),
            "the message should say what a key looks like"
        )
    }
}
