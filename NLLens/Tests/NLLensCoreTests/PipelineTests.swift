import XCTest
@testable import NLLensCore

private func block(_ id: Int, _ text: String, y: Double = 0) -> TextBlock {
    TextBlock(
        id: id, text: text,
        box: BoundingBox(x: 0.1, y: y, width: 0.5, height: 0.04),
        confidence: 0.9
    )
}

final class PipelineTests: XCTestCase {

    private func makePipeline(
        transport: MockTransport,
        cache: TranslationCache? = nil,
        settings: AppSettings = .default
    ) -> TranslationPipeline {
        TranslationPipeline(
            client: .test(transport: transport),
            cache: cache,
            settings: settings,
            textModel: "test/text-model"
        )
    }

    func testTranslatesAndPreservesOrderAndGeometry() async throws {
        let transport = MockTransport(completion: """
        [{"id":0,"nl":"Openen","en":"Open"},{"id":1,"nl":"Annuleren","en":"Cancel"}]
        """)
        let pipeline = makePipeline(transport: transport)

        let outcome = try await pipeline.translate(blocks: [
            block(0, "Openen", y: 0.1),
            block(1, "Annuleren", y: 0.5),
        ])

        XCTAssertEqual(outcome.blocks.map(\.translatedText), ["Open", "Cancel"])
        XCTAssertEqual(outcome.blocks[0].box.y, 0.1, accuracy: 0.0001)
        XCTAssertEqual(outcome.blocks[1].box.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(outcome.networkBlocks, 2)
    }

    func testMissingIDFallsBackToSourceRatherThanBlanking() async throws {
        // The model returned only one of two entries. The other must still
        // render something, not vanish.
        let transport = MockTransport(completion: #"[{"id":0,"nl":"Openen","en":"Open"}]"#)
        let pipeline = makePipeline(transport: transport)

        let outcome = try await pipeline.translate(blocks: [
            block(0, "Openen", y: 0.1),
            block(1, "Annuleren", y: 0.5),
        ])

        XCTAssertEqual(outcome.blocks.count, 2)
        XCTAssertEqual(outcome.blocks[1].translatedText, "Annuleren")
    }

    func testExtraAndDuplicateIDsDoNotCrash() async throws {
        let transport = MockTransport(completion: """
        [{"id":0,"nl":"A","en":"A1"},{"id":0,"nl":"A","en":"A2"},{"id":99,"nl":"X","en":"X"}]
        """)
        let pipeline = makePipeline(transport: transport)

        let outcome = try await pipeline.translate(blocks: [block(0, "Openen")])
        XCTAssertEqual(outcome.blocks.count, 1)
        XCTAssertEqual(outcome.blocks[0].translatedText, "A1", "first wins")
    }

    func testNumericRunsSkipTheNetworkEntirely() async throws {
        let transport = MockTransport(stubs: [])
        let pipeline = makePipeline(transport: transport)

        let outcome = try await pipeline.translate(blocks: [
            block(0, "€ 24,95", y: 0.1),
            block(1, "12:45", y: 0.3),
        ])

        XCTAssertEqual(transport.requestCount, 0, "pure numbers must not be sent")
        XCTAssertEqual(outcome.blocks.count, 2)
        XCTAssertTrue(outcome.servedEntirelyFromCache)
    }

    func testRedactionMasksIBANOnTheWireAndRestoresAfter() async throws {
        // Echo the placeholder back the way a well-behaved model would.
        let transport = MockTransport(completion: """
        [{"id":0,"nl":"Rekening [[R1]]","en":"Account [[R1]]"}]
        """)
        let pipeline = makePipeline(transport: transport)

        let outcome = try await pipeline.translate(blocks: [
            block(0, "Rekening NL91ABNA0417164300")
        ])

        let sentBody = transport.recordedBodies().joined()
        XCTAssertFalse(
            sentBody.contains("NL91ABNA0417164300"),
            "the IBAN must never appear in the request body"
        )
        XCTAssertTrue(sentBody.contains("[[R1]]"))
        XCTAssertEqual(outcome.blocks[0].translatedText, "Account NL91ABNA0417164300")
        XCTAssertEqual(outcome.redactedCount, 1)
        XCTAssertEqual(outcome.redactedKinds, [.iban])
    }

    func testCacheHitAvoidsNetworkOnSecondRun() async throws {
        let cacheURL = temporaryCacheURL()
        let cache = TranslationCache(fileURL: cacheURL)
        try await cache.load()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let first = MockTransport(completion: #"[{"id":0,"nl":"Instellingen","en":"Settings"}]"#)
        let outcome1 = try await makePipeline(transport: first, cache: cache)
            .translate(blocks: [block(0, "Instellingen")])
        XCTAssertEqual(outcome1.networkBlocks, 1)
        XCTAssertEqual(first.requestCount, 1)

        let second = MockTransport(stubs: [])
        let outcome2 = try await makePipeline(transport: second, cache: cache)
            .translate(blocks: [block(0, "Instellingen")])

        XCTAssertEqual(second.requestCount, 0, "second run must be served from cache")
        XCTAssertEqual(outcome2.blocks[0].translatedText, "Settings")
        XCTAssertTrue(outcome2.blocks[0].fromCache)
        XCTAssertTrue(outcome2.servedEntirelyFromCache)
    }

    func testCloudDisabledThrowsRatherThanLeaking() async throws {
        var settings = AppSettings.default
        settings.cloudEnabled = false

        let transport = MockTransport(stubs: [])
        let pipeline = makePipeline(transport: transport, settings: settings)

        do {
            _ = try await pipeline.translate(blocks: [block(0, "Openen")])
            XCTFail("expected cloudDisabled")
        } catch let error as PipelineError {
            XCTAssertEqual(error, .cloudDisabled)
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testBatchingSplitsLargeScreens() async throws {
        let count = TranslationPipeline.batchSize + 5
        let blocks = (0..<count).map { block($0, "Knop \($0)", y: Double($0) * 0.02) }

        // Grouping may merge some; respond generously so every id is covered.
        func units(_ range: Range<Int>) -> String {
            let items = range.map { #"{"id":\#($0),"nl":"Knop \#($0)","en":"Button \#($0)"}"# }
            return "[" + items.joined(separator: ",") + "]"
        }
        let transport = MockTransport(stubs: [
            .completion(units(0..<count)), .completion(units(0..<count)),
        ])
        let pipeline = makePipeline(transport: transport)

        let outcome = try await pipeline.translate(blocks: blocks)
        XCTAssertFalse(outcome.blocks.isEmpty)
        XCTAssertLessThanOrEqual(transport.requestCount, 2)
    }

    func testComposeRestoresRedactedValues() async throws {
        let transport = MockTransport(completion: """
        {"dutch":"Mijn rekening is [[R1]].","notes":["Formeel: 'u' gebruikt."]}
        """)
        let pipeline = makePipeline(transport: transport)

        let result = try await pipeline.compose(
            english: "My account is NL91ABNA0417164300.",
            register: .formal
        )

        XCTAssertEqual(result.dutch, "Mijn rekening is NL91ABNA0417164300.")
        XCTAssertFalse(transport.recordedBodies().joined().contains("NL91ABNA0417164300"))
    }

    func testExplainParsesStructuredResult() async throws {
        let transport = MockTransport(completion: """
        Here you go:
        ```json
        {"summary":"Payment failed","actions":["Try another card"],"warnings":["Auto-renews monthly"]}
        ```
        """)
        let pipeline = makePipeline(transport: transport)

        let result = try await pipeline.explain(
            imageBase64: "AAAA", visionModel: "test/vision-model"
        )
        XCTAssertEqual(result.summary, "Payment failed")
        XCTAssertEqual(result.warnings, ["Auto-renews monthly"])
    }

    func testExplainSendsImageAsDataURL() async throws {
        let transport = MockTransport(completion: #"{"summary":"x","actions":[],"warnings":[]}"#)
        let pipeline = makePipeline(transport: transport)

        _ = try await pipeline.explain(
            imageBase64: "QUJD", mimeType: "image/jpeg", visionModel: "test/vision-model"
        )
        let body = transport.recordedBodies().joined()
        XCTAssertTrue(body.contains("data:image/jpeg;base64,QUJD"))
        XCTAssertTrue(body.contains("image_url"))
    }
}
