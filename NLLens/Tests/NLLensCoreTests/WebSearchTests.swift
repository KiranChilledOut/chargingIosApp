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
        XCTAssertEqual(TavilyClient.mapStatus(500), .serverError(status: 500, message: ""))
    }

    /// 432 and 433 are documented as plan and pay-as-you-go limits. The key is
    /// valid in both cases, so reporting them as a rejected key sends someone
    /// off to regenerate a key that was never the problem.
    func testQuotaCodesAreNotKeyFailures() {
        let body = Data(#"{"detail":{"error":"This request exceeds your plan's set usage limit."}}"#.utf8)
        XCTAssertEqual(
            TavilyClient.mapStatus(432, body: body),
            .outOfCredits(message: "This request exceeds your plan's set usage limit.")
        )
        XCTAssertEqual(
            TavilyClient.mapStatus(433, body: Data()),
            .outOfCredits(message: "")
        )
    }

    /// Tavily nests the reason as `{"detail": {"error": ...}}` — an object,
    /// where Nebius puts a bare string. Reading only one shape leaves the
    /// reason blank exactly when it is needed.
    func testTavilyErrorMessageIsExtracted() {
        XCTAssertEqual(
            TavilyClient.errorMessage(
                from: Data(#"{"detail":{"error":"Unauthorized: missing or invalid API key."}}"#.utf8)
            ),
            "Unauthorized: missing or invalid API key."
        )
        XCTAssertEqual(
            TavilyClient.errorMessage(from: Data(#"{"detail":"plain string"}"#.utf8)),
            "plain string"
        )
        XCTAssertEqual(TavilyClient.errorMessage(from: Data("not json".utf8)), "")
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

    /// The wiring, not just the wording: a failed lookup has to reach the
    /// model, or it goes on claiming it has no search tool.
    func testTheFailureReachesTheSystemPrompt() async throws {
        let chat = MockTransport(completion: "answered anyway")
        _ = try await pipeline(
            chat,
            searchTransport: MockTransport(stubs: [.json("{}", status: 401)])
        ).answer(in: conversation)

        let body = try XCTUnwrap(chat.requests.first?.body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(
            system.lowercased().contains("do not say you have no search tool"),
            "the model must be told the lookup failed, not left to guess"
        )
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
        XCTAssertTrue(reason.contains("key"), "the note must name what failed: \(reason)")
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

    /// The first version of this message asserted the MCP URL was pasted.
    /// Tavily returns an identical 401 for a rotated key, a mistyped key, a
    /// key from another account and no key at all, so naming one cause is a
    /// guess presented as a diagnosis — and it sent a real user to re-check
    /// something that was already correct.
    func testUnauthorizedMessageDoesNotGuessACause() {
        let message = WebSearchError.unauthorized.userMessage
        XCTAssertFalse(message.contains("MCP"), "the response cannot support that claim")
        XCTAssertTrue(message.contains("Test key"), "point at the check instead")
    }
}

/// A failed search cannot say why it failed — Tavily's 401 is identical for
/// every cause. `check()` is the only thing that can, so it carries the weight
/// of the whole diagnosis.
final class TavilyKeyCheckTests: XCTestCase {

    private let key = "tvly-prod-abc123DEF456xyz789"

    private func client(_ transport: MockTransport, key: String? = nil) -> TavilyClient {
        TavilyClient(apiKey: key ?? self.key, transport: transport)
    }

    func testWorkingKeyReportsResultCount() async {
        let body = #"{"results":[{"url":"https://a.nl","title":"A","content":"x"}]}"#
        let check = await client(MockTransport(stubs: [.json(body)])).check()
        XCTAssertTrue(check.isWorking)
        XCTAssertEqual(check.outcome, .working(resultCount: 1))
        XCTAssertNil(check.advice, "nothing to do when it works")
    }

    func testRejectedKeyNamesEveryCauseRatherThanGuessingOne() async {
        let body = #"{"detail":{"error":"Unauthorized: missing or invalid API key."}}"#
        let check = await client(MockTransport(stubs: [.json(body, status: 401)])).check()

        XCTAssertEqual(check.outcome, .rejected)
        let advice = check.advice ?? ""
        XCTAssertTrue(advice.contains("rotated"))
        XCTAssertTrue(advice.contains("mistyped"))
        XCTAssertTrue(advice.contains("different account"))
    }

    func testOutOfCreditsIsNotReportedAsABadKey() async {
        let body = #"{"detail":{"error":"This request exceeds your plan's set usage limit."}}"#
        let check = await client(MockTransport(stubs: [.json(body, status: 432)])).check()

        XCTAssertEqual(check.outcome, .outOfCredits)
        XCTAssertTrue(check.headline.contains("valid"), "the key is fine; the plan is not")
        XCTAssertEqual(check.serverMessage, "This request exceeds your plan's set usage limit.")
    }

    func testNoKeyIsDistinctFromARejectedOne() async {
        let transport = MockTransport(stubs: [])
        let check = await client(transport, key: "").check()
        XCTAssertEqual(check.outcome, .noKey)
        XCTAssertEqual(transport.requestCount, 0, "nothing to test, so nothing is sent")
    }

    func testAStoredNonKeyIsNamedForWhatItIs() async {
        let transport = MockTransport(stubs: [])
        // A URL with no key parameter survives normalization intact, and is
        // worth catching before spending a request on it.
        let check = await client(transport, key: "https://mcp.tavily.com/mcp/").check()
        XCTAssertEqual(check.outcome, .notAKey(looksLike: "a web address"))
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testShapeNamesWhatWasStored() {
        XCTAssertEqual(TavilyClient.shape(of: "https://x.nl"), "a web address")
        XCTAssertEqual(TavilyClient.shape(of: "my key is here"), "a sentence")
        XCTAssertEqual(TavilyClient.shape(of: "garbage"), "ordinary text")
        XCTAssertEqual(TavilyClient.shape(of: "   "), "nothing")
    }
}

/// The Settings field starts empty on every launch, so there is no way to see
/// which key is actually stored — and a rotated key fails exactly like a wrong
/// one. The preview is what makes the two distinguishable.
final class TavilyKeyPreviewTests: XCTestCase {

    func testPreviewShowsEnoughToCompareAgainstTheDashboard() {
        let preview = TavilyClient.preview(of: "tvly-prod-abc123DEF456xyz789")
        XCTAssertTrue(preview.hasPrefix("tvly-prod-"))
        XCTAssertTrue(preview.contains("z789"), "the tail is what distinguishes two keys")
        XCTAssertTrue(preview.contains("28 characters"))
    }

    func testPreviewNeverShowsTheMiddleOfTheKey() {
        let key = "tvly-prod-SECRETMIDDLEPART1234"
        let preview = TavilyClient.preview(of: key)
        XCTAssertFalse(preview.contains("SECRETMIDDLE"))
        XCTAssertFalse(preview.contains(key))
    }

    func testPreviewOfAURLShowsTheExtractedKey() {
        let preview = TavilyClient.preview(
            of: "https://mcp.tavily.com/mcp/?tavilyApiKey=tvly-prod-abc123DEF456xyz789"
        )
        XCTAssertTrue(preview.hasPrefix("tvly-prod-"))
        XCTAssertFalse(preview.contains("mcp.tavily.com"))
    }

    func testEmptyAndShortValuesAreDescribedPlainly() {
        XCTAssertEqual(TavilyClient.preview(of: "   "), "nothing saved")
        XCTAssertTrue(TavilyClient.preview(of: "tvly-abc").contains("too short"))
    }
}

/// A failed lookup used to reach the model as an empty string, so the model
/// explained the gap itself — with "I don't have a search tool connected in
/// this conversation", which is wrong and makes a working feature sound
/// missing. The outcome is now stated.
final class SearchModelNoteTests: XCTestCase {

    func testASuccessfulSearchNeedsNoNote() {
        XCTAssertEqual(SearchStatus.searched(count: 3).modelNote, "")
        XCTAssertEqual(SearchStatus.skipped.modelNote, "")
    }

    func testAFailedLookupIsExplainedRatherThanDisowned() {
        let note = SearchStatus.failed("Tavily did not accept this key.").modelNote
        XCTAssertTrue(note.contains("Tavily did not accept this key."), "carry the reason")
        XCTAssertTrue(note.contains("failed"))
        XCTAssertTrue(
            note.lowercased().contains("do not say you have no search tool"),
            "the exact failure mode seen on device"
        )
    }

    func testAMissingKeyIsNotReportedAsAnInability() {
        let note = SearchStatus.unavailable.modelNote
        XCTAssertTrue(note.contains("no search key"))
        XCTAssertTrue(note.lowercased().contains("do not say you are unable to search"))
    }
}
