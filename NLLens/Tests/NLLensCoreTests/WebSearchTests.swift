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
