import XCTest
@testable import NLLensCore

final class NebiusClientTests: XCTestCase {

    func testMissingKeyFailsBeforeAnyRequest() async {
        let transport = MockTransport(stubs: [])
        let client = NebiusClient(
            configuration: NebiusConfiguration(apiKey: "   "),
            transport: transport,
            sleeper: { _ in }
        )
        do {
            _ = try await client.complete(messages: [.user("hi")], model: "m")
            XCTFail("expected missingAPIKey")
        } catch let error as NebiusError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testUnauthorizedIsNotRetried() async {
        let transport = MockTransport(stubs: [
            .json(#"{"error":{"message":"bad key"}}"#, status: 401),
            .completion("should never be reached"),
        ])
        let client = NebiusClient.test(transport: transport)

        do {
            _ = try await client.complete(messages: [.user("hi")], model: "m")
            XCTFail("expected unauthorized")
        } catch let error as NebiusError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 1, "auth failures must not retry")
    }

    func testRateLimitIsRetriedThenSucceeds() async throws {
        let transport = MockTransport(stubs: [
            .json(#"{"error":{"message":"slow down"}}"#, status: 429),
            .completion("ok"),
        ])
        let client = NebiusClient.test(transport: transport)

        let result = try await client.complete(messages: [.user("hi")], model: "m")
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testServerErrorRetriesUpToLimitThenThrows() async {
        let transport = MockTransport(stubs: [
            .json("{}", status: 500), .json("{}", status: 500), .json("{}", status: 500),
        ])
        let client = NebiusClient.test(transport: transport, maxRetries: 2)

        do {
            _ = try await client.complete(messages: [.user("hi")], model: "m")
            XCTFail("expected serverError")
        } catch let error as NebiusError {
            guard case .serverError = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 3, "initial attempt plus two retries")
    }

    func testTransportFailureIsRetried() async throws {
        let transport = MockTransport(stubs: [.completion("recovered")], failuresRemaining: 1)
        let client = NebiusClient.test(transport: transport)

        let result = try await client.complete(messages: [.user("hi")], model: "m")
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testEmptyCompletionIsAnError() async {
        let transport = MockTransport(completion: "   ")
        let client = NebiusClient.test(transport: transport)
        do {
            _ = try await client.complete(messages: [.user("hi")], model: "m")
            XCTFail("expected emptyCompletion")
        } catch let error as NebiusError {
            XCTAssertEqual(error, .emptyCompletion)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testContentAsPartsArrayIsHandled() throws {
        // Some reasoning-style models return content as an array of parts.
        let payload: [String: Any] = [
            "choices": [["message": ["content": [["type": "text", "text": "hello"]]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let client = NebiusClient.test(transport: MockTransport(stubs: []))
        XCTAssertEqual(try client.extractContent(from: data), "hello")
    }

    func testAuthHeaderAndModelAreSent() async throws {
        let transport = MockTransport(completion: "ok")
        let client = NebiusClient.test(transport: transport)
        _ = try await client.complete(messages: [.user("hi")], model: "my/model")

        XCTAssertEqual(transport.requests.first?.headers["Authorization"], "Bearer test-key")
        XCTAssertTrue(transport.recordedBodies().joined().contains("my/model"))
    }

    func testTextOnlyMessageUsesStringContentForm() async throws {
        let transport = MockTransport(completion: "ok")
        let client = NebiusClient.test(transport: transport)
        _ = try await client.complete(messages: [.user("plain")], model: "m")

        let body = transport.recordedBodies().joined()
        XCTAssertTrue(body.contains(#""content":"plain""#), "got: \(body)")
    }

    func testListModelsParsesCatalog() async throws {
        let transport = MockTransport(stubs: [
            .json(#"{"data":[{"id":"a/model-1"},{"id":"b/model-2"}]}"#)
        ])
        let client = NebiusClient.test(transport: transport)
        let models = try await client.listModels()
        XCTAssertEqual(models.map(\.id), ["a/model-1", "b/model-2"])
    }

    func testErrorMessageExtraction() {
        let body = Data(#"{"error":{"message":"model not found"}}"#.utf8)
        XCTAssertEqual(NebiusClient.errorMessage(from: body), "model not found")
    }

    func testNebiusDetailEnvelopeIsRead() {
        // Verified against the live endpoint: Nebius returns `detail`, not the
        // OpenAI `error.message` shape.
        let body = Data(#"{"detail":"Couldn't authenticate. Reason: token is not present"}"#.utf8)
        XCTAssertEqual(
            NebiusClient.errorMessage(from: body),
            "Couldn't authenticate. Reason: token is not present"
        )
    }

    func testFastAPIValidationDetailArrayIsRead() {
        let body = Data(#"{"detail":[{"loc":["body","model"],"msg":"field required","type":"value_error"}]}"#.utf8)
        XCTAssertEqual(NebiusClient.errorMessage(from: body), "field required")
    }

    func testClientErrorSurfacesTheReason() {
        let body = Data(#"{"detail":"unknown model: bogus/model"}"#.utf8)
        let error = NebiusClient.mapStatus(404, body: body)
        XCTAssertEqual(error.userMessage, "unknown model: bogus/model")
    }
}

final class ResponseFormatTests: XCTestCase {

    func testSchemaIsSentOnTheWire() async throws {
        let transport = MockTransport(completion: "ok")
        let client = NebiusClient.test(transport: transport)
        _ = try await client.complete(
            messages: [.user("hi")], model: "m",
            responseFormat: .jsonSchema(Schemas.translationUnits)
        )
        let body = transport.recordedBodies().joined()
        XCTAssertTrue(body.contains("response_format"))
        XCTAssertTrue(body.contains("json_schema"))
        XCTAssertTrue(body.contains(#""nl""#), "schema properties should be present")
    }

    func testJSONObjectModeWireShape() async throws {
        let transport = MockTransport(completion: "ok")
        let client = NebiusClient.test(transport: transport)
        _ = try await client.complete(
            messages: [.user("hi")], model: "m", responseFormat: .jsonObject
        )
        XCTAssertTrue(transport.recordedBodies().joined().contains("json_object"))
    }

    func testUnsupportedResponseFormatFallsBackWithoutIt() async throws {
        // A model that does not implement response_format rejects the request.
        // The client should drop the constraint and try once more.
        let transport = MockTransport(stubs: [
            .json(#"{"detail":"response_format is not supported"}"#, status: 400),
            .completion("recovered"),
        ])
        let client = NebiusClient.test(transport: transport)

        let result = try await client.complete(
            messages: [.user("hi")], model: "m",
            responseFormat: .jsonSchema(Schemas.translationUnits)
        )
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(transport.requestCount, 2)

        let bodies = transport.recordedBodies()
        XCTAssertTrue(bodies[0].contains("response_format"), "first attempt constrained")
        XCTAssertFalse(bodies[1].contains("response_format"), "retry must drop it")
    }

    func testNoFallbackLoopWhenNoResponseFormatWasSet() async {
        let transport = MockTransport(stubs: [.json(#"{"detail":"bad"}"#, status: 400)])
        let client = NebiusClient.test(transport: transport)

        do {
            _ = try await client.complete(messages: [.user("hi")], model: "m")
            XCTFail("expected clientError")
        } catch let error as NebiusError {
            guard case .clientError = error else { return XCTFail("wrong: \(error)") }
        } catch {
            XCTFail("wrong: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 1, "must not retry without a format to drop")
    }

    func testAuthFailureIsNotTreatedAsAFormatProblem() async {
        let transport = MockTransport(stubs: [
            .json(#"{"detail":"Couldn't authenticate"}"#, status: 401),
            .completion("should not be reached"),
        ])
        let client = NebiusClient.test(transport: transport)

        do {
            _ = try await client.complete(
                messages: [.user("hi")], model: "m", responseFormat: .jsonObject
            )
            XCTFail("expected unauthorized")
        } catch let error as NebiusError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }
}

/// The chat failure that shipped: a reasoning model given a small budget spent
/// it all thinking, returned HTTP 200 with an empty `content`, and the app said
/// "the model returned nothing" — sending the user to look for a bug in their
/// question rather than at the token budget.
final class CompletionExtractionTests: XCTestCase {

    private var client: NebiusClient {
        .test(transport: MockTransport(stubs: []))
    }

    private func body(_ message: [String: Any], finish: String? = nil) -> Data {
        var choice: [String: Any] = ["message": message]
        if let finish { choice["finish_reason"] = finish }
        return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }

    func testPlainContent() throws {
        XCTAssertEqual(
            try client.extractContent(from: body(["content": "  hello  "])), "hello"
        )
    }

    func testEmptyContentCutShortIsReportedAsTruncation() throws {
        // The actual bug. This must not read as "returned nothing".
        XCTAssertThrowsError(
            try client.extractContent(from: body(["content": ""], finish: "length"))
        ) { error in
            XCTAssertEqual(error as? NebiusError, .truncated)
        }
    }

    func testTruncationMessagePointsAtTheRealCause() {
        XCTAssertTrue(
            NebiusError.truncated.userMessage.lowercased().contains("ran out of room")
        )
    }

    func testReasoningContentIsUsedRatherThanDiscarded() throws {
        // Some models put everything in the reasoning channel. A verbose
        // answer beats no answer.
        let text = try client.extractContent(
            from: body(["content": "", "reasoning_content": "The answer is B."])
        )
        XCTAssertEqual(text, "The answer is B.")
    }

    func testContentWinsOverReasoning() throws {
        let text = try client.extractContent(
            from: body(["content": "Final answer.", "reasoning_content": "thinking…"])
        )
        XCTAssertEqual(text, "Final answer.")
    }

    func testGenuinelyEmptyStillReportsEmpty() throws {
        XCTAssertThrowsError(try client.extractContent(from: body(["content": ""]))) { error in
            XCTAssertEqual(error as? NebiusError, .emptyCompletion)
        }
    }

    func testTruncationOutranksReasoningFallback() throws {
        // Cut off mid-thought: the thought is not an answer.
        XCTAssertThrowsError(
            try client.extractContent(
                from: body(["content": "", "reasoning_content": ""], finish: "length")
            )
        ) { error in
            XCTAssertEqual(error as? NebiusError, .truncated)
        }
    }

    func testNoneOfTheseErrorsRetry() {
        // Retrying an empty or truncated reply just spends money again.
        XCTAssertFalse(NebiusError.truncated.isRetryable)
        XCTAssertFalse(NebiusError.emptyCompletion.isRetryable)
    }
}
