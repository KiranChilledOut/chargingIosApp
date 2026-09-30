import XCTest
@testable import NLLensCore

final class ModelChainTests: XCTestCase {

    func testAChainCanBeWrittenWhereAModelIdWas() {
        let chain: ModelChain = "one/model"
        XCTAssertEqual(chain.models, ["one/model"])
        XCTAssertEqual(chain.primary, "one/model")
        XCTAssertTrue(chain.backups.isEmpty)
    }

    /// A picker set to "None" yields an empty string, and a backup set to the
    /// same value as the primary would fail twice before moving on.
    func testEmptiesAndDuplicatesAreDropped() {
        let chain = ModelChain(["a/one", "", "  ", "a/one", "b/two"])
        XCTAssertEqual(chain.models, ["a/one", "b/two"])
    }

    func testPrimaryAndBackupsSplitAsWritten() {
        let chain = ModelChain(primary: "a", backups: ["b", "c"])
        XCTAssertEqual(chain.primary, "a")
        XCTAssertEqual(chain.backups, ["b", "c"])
    }

    func testAnEmptyChainIsEmptyRatherThanAnEmptyModelId() {
        XCTAssertTrue(ModelChain([]).isEmpty)
        XCTAssertTrue(ModelChain(["", " "]).isEmpty)
    }
}

/// The policy is the whole design. Falling back on everything is worse than
/// not falling back at all — a rejected key fails identically on every model,
/// so a three-model chain turns one immediate error into three round trips,
/// the same message, and a bill for two of them.
final class ModelFallbackPolicyTests: XCTestCase {

    func testAccountProblemsDoNotFallBack() {
        XCTAssertFalse(ModelFallback.worthTryingAnother(NebiusError.unauthorized))
        XCTAssertFalse(ModelFallback.worthTryingAnother(NebiusError.missingAPIKey))
    }

    /// The failure that started this: a model deployed text-only rejecting an
    /// image, and a model that ignores the response format.
    func testModelProblemsDoFallBack() {
        XCTAssertTrue(ModelFallback.worthTryingAnother(
            NebiusError.clientError(status: 400, message: "model does not accept image input")
        ))
        XCTAssertTrue(ModelFallback.worthTryingAnother(JSONExtraction.Error.decodingFailed("x")))
        XCTAssertTrue(ModelFallback.worthTryingAnother(JSONExtraction.Error.noJSONFound))
        XCTAssertTrue(ModelFallback.worthTryingAnother(NebiusError.emptyCompletion))
        XCTAssertTrue(ModelFallback.worthTryingAnother(NebiusError.truncated))
        XCTAssertTrue(ModelFallback.worthTryingAnother(
            NebiusError.serverError(status: 503, message: "")
        ))
        XCTAssertTrue(ModelFallback.worthTryingAnother(NebiusError.rateLimited))
    }

    /// Three timeouts for one message is the worst possible answer to a dead
    /// network.
    func testNetworkFailuresDoNotFallBack() {
        XCTAssertFalse(ModelFallback.worthTryingAnother(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ModelFallback.worthTryingAnother(URLError(.timedOut)))
    }

    func testNonModelFailuresDoNotFallBack() {
        XCTAssertFalse(ModelFallback.worthTryingAnother(PipelineError.cloudDisabled))
        XCTAssertFalse(ModelFallback.worthTryingAnother(WebSearchError.unauthorized))
    }

    func testAnUnknownErrorIsNotWorthSpendingARoundTripOn() {
        struct Mystery: Error {}
        XCTAssertFalse(ModelFallback.worthTryingAnother(Mystery()))
    }
}

final class ModelFallbackRunTests: XCTestCase {

    private actor Calls {
        var models: [String] = []
        func record(_ model: String) { models.append(model) }
    }

    func testTheFirstWorkingModelAnswersAndTheRestAreNotTried() async throws {
        let calls = Calls()
        let attempt = try await ModelFallback.run(chain: ModelChain(["a", "b", "c"])) { model in
            await calls.record(model)
            return "answered by \(model)"
        }

        XCTAssertEqual(attempt.value, "answered by a")
        XCTAssertEqual(attempt.model, "a")
        XCTAssertFalse(attempt.usedFallback)
        let tried = await calls.models
        XCTAssertEqual(tried, ["a"])
    }

    func testAFailingModelHandsOverToTheNext() async throws {
        let calls = Calls()
        let attempt = try await ModelFallback.run(chain: ModelChain(["a", "b"])) { model in
            await calls.record(model)
            if model == "a" { throw JSONExtraction.Error.decodingFailed("ignored the schema") }
            return "answered by \(model)"
        }

        XCTAssertEqual(attempt.model, "b")
        XCTAssertTrue(attempt.usedFallback)
        XCTAssertEqual(attempt.skipped.map(\.model), ["a"])
        XCTAssertTrue(attempt.skipped[0].reason.contains("wrong shape"))
        let tried = await calls.models
        XCTAssertEqual(tried, ["a", "b"])
    }

    func testAnAccountErrorStopsAtTheFirstModel() async {
        let calls = Calls()
        do {
            _ = try await ModelFallback.run(chain: ModelChain(["a", "b", "c"])) { model in
                await calls.record(model)
                throw NebiusError.unauthorized
            }
            XCTFail("expected the error to surface immediately")
        } catch {
            XCTAssertEqual(error as? NebiusError, .unauthorized)
        }

        let tried = await calls.models
        XCTAssertEqual(tried, ["a"], "a bad key is a bad key on every model")
    }

    /// The last model's error, not the first — the last one is the one that
    /// ran with nothing left to try.
    func testWhenEveryModelFailsTheLastReasonSurfaces() async {
        do {
            _ = try await ModelFallback.run(chain: ModelChain(["a", "b"])) { model in
                if model == "a" { throw NebiusError.emptyCompletion }
                throw NebiusError.clientError(status: 404, message: "no such model: b")
            }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(
                error as? NebiusError, .clientError(status: 404, message: "no such model: b")
            )
        }
    }

    func testAllThreeCanBeTriedInOrder() async throws {
        let calls = Calls()
        let attempt = try await ModelFallback.run(chain: ModelChain(["a", "b", "c"])) { model in
            await calls.record(model)
            guard model == "c" else { throw NebiusError.rateLimited }
            return model
        }

        XCTAssertEqual(attempt.model, "c")
        XCTAssertEqual(attempt.skipped.map(\.model), ["a", "b"])
        let tried = await calls.models
        XCTAssertEqual(tried, ["a", "b", "c"])
    }

    func testAnEmptyChainSaysToPickAModelRatherThanFailingObscurely() async {
        do {
            _ = try await ModelFallback.run(chain: ModelChain([])) { _ in "never" }
            XCTFail("expected a throw")
        } catch let error as NebiusError {
            XCTAssertTrue(error.userMessage.contains("Pick one in Settings"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

/// End to end: the chain has to actually be used by the paths people touch.
final class PipelineFallbackTests: XCTestCase {

    private func pipeline(_ transport: MockTransport, chain: ModelChain) -> TranslationPipeline {
        TranslationPipeline(
            client: .test(transport: transport),
            cache: nil,
            settings: .default,
            textModel: chain
        )
    }

    private var conversation: ScreenConversation {
        var c = ScreenConversation(screenText: "Energy contract")
        c.append(role: .user, text: "what is this?")
        return c
    }

    func testChatFallsBackWhenTheFirstModelReturnsNothing() async throws {
        let transport = MockTransport(stubs: [
            .json(#"{"choices":[{"message":{"content":""}}]}"#),
            .completion("the backup answered"),
        ])

        let answer = try await pipeline(transport, chain: ModelChain(["first/model", "second/model"]))
            .answer(in: conversation)

        XCTAssertEqual(answer.text, "the backup answered")
        XCTAssertEqual(answer.modelUsed, "second/model")
        XCTAssertEqual(answer.skippedModels.map(\.model), ["first/model"])

        let bodies = transport.recordedBodies()
        XCTAssertTrue(bodies[0].contains("first/model"))
        XCTAssertTrue(bodies[1].contains("second/model"))
    }

    func testChatDoesNotFallBackOnABadKey() async {
        let transport = MockTransport(stubs: [
            .json(#"{"detail":"bad key"}"#, status: 401),
            .completion("should never be reached"),
        ])

        do {
            _ = try await pipeline(transport, chain: ModelChain(["a", "b"]))
                .answer(in: conversation)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? NebiusError, .unauthorized)
        }
        XCTAssertEqual(transport.requestCount, 1, "one model, one failure, no waiting twice")
    }

    func testTranslationFallsBackWhenAModelIgnoresTheSchema() async throws {
        let transport = MockTransport(stubs: [
            .completion("Sure! Here is your translation, as prose."),
            .completion(#"[{"id":1,"nl":"Hallo","en":"Hello"}]"#),
        ])

        let outcome = try await pipeline(transport, chain: ModelChain(["loose/model", "strict/model"]))
            .translate(blocks: [TextBlock(id: 1, text: "Hallo een zin", box: BoundingBox(x: 0, y: 0, width: 1, height: 0.1))])

        XCTAssertEqual(outcome.blocks.first?.translatedText, "Hello")
        XCTAssertEqual(outcome.modelUsed, "strict/model")
        XCTAssertEqual(outcome.skippedModels.map(\.model), ["loose/model"])
    }
}
