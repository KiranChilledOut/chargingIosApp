import XCTest
@testable import NLLensCore

/// The point of reading a page at all: a Tavily snippet is ~400 characters and
/// the figure someone needs is usually in a table further down. If extraction
/// loses the table, the tool is worse than useless — it burns a round trip and
/// returns the same nothing.
final class WebPageTests: XCTestCase {

    func testATableKeepsItsFiguresBesideTheirLabels() {
        let html = """
        <html><body><h1>Tarieven 2026</h1>
        <table><tr><td>Stroom</td><td>€ 0,24 per kWh</td></tr>
        <tr><td>Gas</td><td>€ 1,09 per m3</td></tr></table>
        </body></html>
        """
        let text = WebPage.text(fromHTML: html)

        XCTAssertTrue(text.contains("Tarieven 2026"))
        // Label and value must stay on one line, or the model reads a column
        // of words and a column of numbers with nothing joining them.
        let stroom = text.split(separator: "\n").first { $0.contains("Stroom") }
        XCTAssertNotNil(stroom)
        XCTAssertTrue(stroom?.contains("0,24") ?? false, "got: \(text)")
    }

    func testScriptAndStyleNeverReachTheModel() {
        let html = """
        <html><head><style>.a{color:red}</style></head>
        <body><script>var secret = "tracking pixel";</script>
        <p>Echte inhoud</p></body></html>
        """
        let text = WebPage.text(fromHTML: html)

        XCTAssertTrue(text.contains("Echte inhoud"))
        XCTAssertFalse(text.contains("tracking pixel"))
        XCTAssertFalse(text.contains("color:red"))
    }

    /// Dutch pages write prices with entities. Left raw, every figure in the
    /// page arrives next to a literal "&euro;".
    func testEntitiesAreDecodedSoPricesRead() {
        let text = WebPage.text(
            fromHTML: "<p>Prijs: &euro;&nbsp;0,24 &amp; stijgend &#8212; per kWh</p>"
        )
        XCTAssertTrue(text.contains("€"))
        XCTAssertTrue(text.contains("&") && !text.contains("&amp;"))
        XCTAssertTrue(text.contains("—"))
        XCTAssertFalse(text.contains("&nbsp;"))
    }

    func testNumericAndHexEntitiesBothDecode() {
        XCTAssertEqual(WebPage.decodeEntities("&#8364;5"), "€5")
        XCTAssertEqual(WebPage.decodeEntities("&#x20AC;5"), "€5")
    }

    func testBlockElementsBecomeLines() {
        let text = WebPage.text(fromHTML: "<p>Een</p><p>Twee</p><div>Drie</div>")
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    /// Nav and cookie bars repeat the same short strings dozens of times, and
    /// every copy is context that the real content then does not get.
    func testRepeatedShortNavigationLinesAreCollapsed() {
        let repeated = String(repeating: "<li>Home</li>", count: 20)
        let text = WebPage.text(fromHTML: "<ul>\(repeated)</ul><p>Inhoud hier</p>")

        XCTAssertEqual(text.components(separatedBy: "Home").count - 1, 1)
        XCTAssertTrue(text.contains("Inhoud hier"))
    }

    func testALongLineIsNotDeduplicated() {
        // Only short lines are nav-like. Two identical long paragraphs are
        // more likely to be real content than chrome.
        let paragraph = "<p>" + String(repeating: "lange zin met inhoud ", count: 5) + "</p>"
        let text = WebPage.text(fromHTML: paragraph + paragraph)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testTruncationCutsAtALineSoNumbersKeepTheirLabels() {
        let rows = (0..<500).map { "<p>Rij \($0): € \($0),50</p>" }.joined()
        let text = WebPage.text(fromHTML: rows, limit: 200)

        XCTAssertLessThanOrEqual(text.count, 220)
        XCTAssertTrue(text.hasSuffix("…"))
        let lines = text.split(separator: "\n").dropLast()
        for line in lines {
            XCTAssertTrue(line.contains("€"), "a row was cut in half: \(line)")
        }
    }

    func testEmptyAndTaglessInputAreHarmless() {
        XCTAssertEqual(WebPage.text(fromHTML: ""), "")
        XCTAssertEqual(WebPage.text(fromHTML: "just words"), "just words")
    }
}

/// The model chooses the URL, and it chooses it partly from pages it has just
/// read. A page that suggests a local address must not turn into a request to
/// one.
final class ReadPageSafetyTests: XCTestCase {

    func testPublicHTTPSIsAllowed() {
        XCTAssertNotNil(ReadPageTool.safeURL("https://www.acm.nl/tarieven"))
        XCTAssertNotNil(ReadPageTool.safeURL("  http://example.nl  "))
    }

    func testNonWebSchemesAreRefused() {
        for raw in ["file:///etc/passwd", "ftp://example.com", "data:text/html,x", "javascript:x"] {
            XCTAssertNil(ReadPageTool.safeURL(raw), "should refuse \(raw)")
        }
    }

    func testLoopbackAndPrivateRangesAreRefused() {
        for raw in [
            "http://localhost/admin", "http://127.0.0.1/", "http://10.0.0.5/",
            "http://192.168.1.1/", "http://169.254.169.254/latest/meta-data/",
            "http://172.16.0.1/", "http://router.local/",
        ] {
            XCTAssertNil(ReadPageTool.safeURL(raw), "should refuse \(raw)")
        }
    }

    func testAddressesThatMerelyLookPrivateAreAllowed() {
        // 172.32 is outside the private range; refusing it would block real sites.
        XCTAssertNotNil(ReadPageTool.safeURL("http://172.32.0.1/"))
        XCTAssertNotNil(ReadPageTool.safeURL("https://10things.nl/"))
    }

    func testGarbageIsRefusedRatherThanCrashing() {
        XCTAssertNil(ReadPageTool.safeURL(""))
        XCTAssertNil(ReadPageTool.safeURL("not a url"))
        XCTAssertNil(ReadPageTool.safeURL("https://"))
    }
}

final class AgentToolTests: XCTestCase {

    func testReadPageReturnsPageTextLabelledAsQuotedMaterial() async throws {
        let html = "<html><body><p>Stroom 2026: € 0,24 per kWh</p></body></html>"
        let transport = MockTransport(stubs: [.json(html)])
        let tool = ReadPageTool(transport: transport)

        let result = try await tool.run(arguments: #"{"url":"https://acm.nl/t"}"#)

        XCTAssertTrue(result.contains("0,24"))
        XCTAssertTrue(
            result.lowercased().contains("quoted material"),
            "a fetched page is text from a stranger and must be framed as such"
        )
        XCTAssertTrue(result.contains("acm.nl"), "say where it came from")
    }

    func testReadPageRefusesAPrivateAddressWithoutFetching() async throws {
        let transport = MockTransport(stubs: [.json("secret")])
        let result = try await ReadPageTool(transport: transport)
            .run(arguments: #"{"url":"http://169.254.169.254/"}"#)

        XCTAssertEqual(transport.requestCount, 0, "nothing should be sent at all")
        XCTAssertTrue(result.contains("not a public web address"))
    }

    func testReadPageReportsAnHTTPErrorAsSomethingToRecoverFrom() async throws {
        let transport = MockTransport(stubs: [.json("nope", status: 404)])
        let result = try await ReadPageTool(transport: transport)
            .run(arguments: #"{"url":"https://example.nl/gone"}"#)

        XCTAssertTrue(result.contains("404"))
        XCTAssertTrue(result.contains("Try another result"))
    }

    /// A tool that cannot read its own arguments says so, rather than throwing
    /// — the model can fix a call it is told is malformed.
    func testMalformedArgumentsComeBackAsGuidance() async throws {
        let result = try await ReadPageTool(transport: MockTransport(stubs: []))
            .run(arguments: "{}")
        XCTAssertTrue(result.contains("Could not read the arguments"))
    }

    func testSearchToolRecordsItsSourcesForCitation() async throws {
        let body = #"""
        {"answer":"About €0.24.","results":[
          {"url":"https://acm.nl/t","title":"Tarieven","content":"Stroom 0,24"}]}
        """#
        let log = SourceLog()
        let tool = SearchTool(
            client: TavilyClient(apiKey: "tvly-test", transport: MockTransport(stubs: [.json(body)])),
            log: log
        )

        let result = try await tool.run(arguments: #"{"query":"stroomprijs 2026"}"#)
        XCTAssertTrue(result.contains("acm.nl"))

        let sources = await log.all
        XCTAssertEqual(sources.map(\.url), ["https://acm.nl/t"])
    }

    func testSourceLogNeverRepeatsAURL() async {
        let log = SourceLog()
        let one = WebSearchResult(title: "T", url: "https://a.nl", snippet: "s")
        await log.add([one])
        await log.add([one, WebSearchResult(title: "U", url: "https://b.nl", snippet: "s")])

        let all = await log.all
        XCTAssertEqual(all.map(\.url), ["https://a.nl", "https://b.nl"])
    }

    func testRecallSaysWhenItKnowsNothingRatherThanReturningEmpty() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let memory = MemoryStore(fileURL: directory.appendingPathComponent("m.jsonl"))

        let result = try await RecallTool(memory: memory)
            .run(arguments: #"{"topic":"energy tariff"}"#)
        XCTAssertTrue(result.contains("Nothing remembered"))
        XCTAssertTrue(result.contains("Ask them"), "tell it what to do instead")
    }

    func testRecallReturnsWhatIsKnown() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryStore(fileURL: directory.appendingPathComponent("m.jsonl"))
        try await memory.record([
            MemoryFact(key: "energy-tariff", label: "Electricity", value: "€0.25970 per kWh")
        ])

        let result = try await RecallTool(memory: memory)
            .run(arguments: #"{"topic":"electricity tariff"}"#)
        XCTAssertTrue(result.contains("0.25970"))
    }
}
