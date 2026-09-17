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

/// Content going missing is the worst failure this app has: it is silent, and
/// the user cannot tell a sentence that was dropped from one that was never
/// on screen.
final class CompletenessTests: XCTestCase {

    private func makePipeline(transport: MockTransport) -> TranslationPipeline {
        TranslationPipeline(
            client: .test(transport: transport),
            cache: nil,
            settings: .default,
            textModel: "test/text-model"
        )
    }

    /// Spaced far enough apart that grouping treats them as separate elements
    /// — otherwise they merge into one paragraph and the test is measuring
    /// grouping rather than completeness.
    private func blocks(_ count: Int) -> [TextBlock] {
        (0..<count).map {
            TextBlock(
                id: $0, text: "Zin nummer \($0)",
                box: BoundingBox(x: 0.1, y: Double($0) * 0.2, width: 0.8, height: 0.03)
            )
        }
    }

    private func units(_ ids: [Int]) -> String {
        "[" + ids.map { #"{"id":\#($0),"nl":"Zin nummer \#($0)","en":"Sentence \#($0)"}"# }
            .joined(separator: ",") + "]"
    }

    func testOmittedRunsAreRequestedAgain() async throws {
        // First reply drops ids 1 and 3; the retry supplies them.
        let transport = MockTransport(stubs: [
            .completion(units([0, 2, 4])),
            .completion(units([1, 3])),
        ])
        let outcome = try await makePipeline(transport: transport).translate(blocks: blocks(5))

        XCTAssertEqual(transport.requestCount, 2, "omissions should trigger one retry")
        XCTAssertEqual(
            outcome.blocks.map(\.translatedText),
            (0..<5).map { "Sentence \($0)" },
            "every run must come back translated, not left as Dutch"
        )
    }

    func testCompleteFirstReplyDoesNotRetry() async throws {
        let transport = MockTransport(stubs: [.completion(units(Array(0..<4)))])
        _ = try await makePipeline(transport: transport).translate(blocks: blocks(4))
        XCTAssertEqual(transport.requestCount, 1, "no retry when nothing was omitted")
    }

    func testRetryFailureStillLeavesSourceTextRatherThanNothing() async throws {
        // The retry errors. The run must still render as Dutch — visible and
        // obviously untranslated — never as a gap.
        let transport = MockTransport(stubs: [
            .completion(units([0, 2])),
            .json(#"{"detail":"boom"}"#, status: 500),
            .json(#"{"detail":"boom"}"#, status: 500),
            .json(#"{"detail":"boom"}"#, status: 500),
        ])
        let outcome = try await makePipeline(transport: transport).translate(blocks: blocks(3))

        XCTAssertEqual(outcome.blocks.count, 3)
        XCTAssertEqual(outcome.blocks[1].translatedText, "Zin nummer 1")
    }

    func testRetryOnlyAsksForWhatWasMissing() async throws {
        let transport = MockTransport(stubs: [
            .completion(units([0])),
            .completion(units([1, 2])),
        ])
        _ = try await makePipeline(transport: transport).translate(blocks: blocks(3))

        let retryBody = transport.recordedBodies()[1]
        XCTAssertTrue(retryBody.contains("Zin nummer 1"))
        XCTAssertTrue(retryBody.contains("Zin nummer 2"))
        XCTAssertFalse(retryBody.contains("Zin nummer 0"), "already translated")
    }

    func testEveryBlockSurvivesABatchBoundary() async throws {
        // More runs than fit one request: nothing may be lost at the seam.
        let count = TranslationPipeline.batchSize * 2 + 3
        let all = Array(0..<count)
        let transport = MockTransport(stubs: [
            .completion(units(all)), .completion(units(all)), .completion(units(all)),
        ])
        let outcome = try await makePipeline(transport: transport)
            .translate(blocks: blocks(count))

        XCTAssertEqual(
            outcome.blocks.count, count,
            "a run was lost crossing a batch boundary"
        )
    }

    func testBatchSizeLeavesRoomForTheReply() {
        // The reply carries repaired Dutch *and* English for every run, so the
        // batch has to stay well under what the output budget can hold.
        XCTAssertLessThanOrEqual(
            TranslationPipeline.batchSize, 25,
            "larger batches get truncated mid-array and the request is wasted"
        )
    }
}
