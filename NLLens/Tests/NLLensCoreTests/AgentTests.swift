import XCTest
@testable import NLLensCore

// MARK: - Wire shape

/// Function calling is the one part of this that cannot be checked by reading:
/// the request has to be a shape the server accepts, and a malformed tool
/// message is rejected wholesale rather than degraded.
final class ToolWireShapeTests: XCTestCase {

    private let weather = ToolDefinition(
        name: "get_weather",
        description: "Weather for a city",
        parameters: [
            "type": "object",
            "properties": ["city": ["type": "string"]],
            "required": ["city"],
        ]
    )

    private func body(
        _ messages: [ChatMessage], tools: [ToolDefinition]
    ) throws -> [String: Any] {
        let client = NebiusClient.test(transport: MockTransport(stubs: []))
        let data = try client.encodeRequestBody(
            messages: messages, model: "m", temperature: 0.2, maxTokens: 100,
            responseFormat: nil, tools: tools
        )
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testToolsAreSentInTheOpenAIShape() throws {
        let object = try body([.user("hi")], tools: [weather])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")

        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertNotNil(function["parameters"])
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
    }

    /// A model that does not do tool calling should see a request it
    /// recognises, not an empty array and a tool_choice it cannot honour.
    func testNoToolsMeansNoToolKeysAtAll() throws {
        let object = try body([.user("hi")], tools: [])
        XCTAssertNil(object["tools"])
        XCTAssertNil(object["tool_choice"])
    }

    func testAnAssistantTurnReplaysItsToolCalls() throws {
        let turn = AssistantTurn(
            text: "",
            toolCalls: [ToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Utrecht"}"#)]
        )
        let object = try body([.user("weather?"), .assistant(turn)], tools: [weather])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])

        let assistant = messages[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertNil(
            assistant["content"],
            "a turn that only asks for tools has no text, and an empty string is rejected"
        )

        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls[0]["id"] as? String, "call_1")
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(
            function["arguments"] as? String, #"{"city":"Utrecht"}"#,
            "arguments stay a JSON string, not a nested object"
        )
    }

    func testAToolResultCarriesTheCallItAnswers() throws {
        let object = try body(
            [.toolResult(callID: "call_1", name: "get_weather", content: "12°C")],
            tools: [weather]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "tool")
        XCTAssertEqual(messages[0]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[0]["name"] as? String, "get_weather")
        XCTAssertEqual(messages[0]["content"] as? String, "12°C")
    }
}

// MARK: - Response parsing

final class AssistantTurnParsingTests: XCTestCase {

    private func turn(_ json: String) throws -> AssistantTurn {
        try NebiusClient.test(transport: MockTransport(stubs: []))
            .extractTurn(from: Data(json.utf8))
    }

    /// The reply the whole loop exists to handle. `extractContent` would throw
    /// `emptyCompletion` on this — correct for a plain completion, and exactly
    /// wrong here.
    func testToolCallsWithNoContentAreNotAnEmptyCompletion() throws {
        let parsed = try turn(#"""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_9","type":"function","function":{"name":"search_web",
           "arguments":"{\"query\":\"stroomprijs 2026\"}"}}]}}]}
        """#)

        XCTAssertTrue(parsed.wantsTools)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.toolCalls[0].id, "call_9")
        XCTAssertEqual(parsed.toolCalls[0].name, "search_web")
        XCTAssertEqual(parsed.toolCalls[0].arguments, #"{"query":"stroomprijs 2026"}"#)
        XCTAssertTrue(parsed.text.isEmpty)
    }

    func testAPlainAnswerCarriesNoToolCalls() throws {
        let parsed = try turn(#"{"choices":[{"message":{"content":"About €0.26."}}]}"#)
        XCTAssertFalse(parsed.wantsTools)
        XCTAssertEqual(parsed.text, "About €0.26.")
    }

    func testAMissingCallIdIsSubstitutedRatherThanDroppingTheCall() throws {
        let parsed = try turn(#"""
        {"choices":[{"message":{"tool_calls":[
          {"type":"function","function":{"name":"read_page","arguments":"{}"}}]}}]}
        """#)
        XCTAssertEqual(parsed.toolCalls.count, 1, "a missing id must not lose the call")
        XCTAssertFalse(parsed.toolCalls[0].id.isEmpty)
    }

    func testTruncationIsStillReportedWhenThereIsNothingAtAll() throws {
        XCTAssertThrowsError(
            try turn(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#)
        ) { error in
            XCTAssertEqual(error as? NebiusError, .truncated)
        }
    }
}

// MARK: - The loop

private struct StubTool: AgentTool {
    let definition: ToolDefinition
    let reply: String
    let shouldThrow: Bool

    init(name: String, reply: String = "ok", shouldThrow: Bool = false) {
        self.definition = ToolDefinition(
            name: name, description: "test", parameters: ["type": "object"]
        )
        self.reply = reply
        self.shouldThrow = shouldThrow
    }

    func run(arguments: String) async throws -> String {
        if shouldThrow { throw WebSearchError.rateLimited }
        return reply
    }
}

final class AgentLoopTests: XCTestCase {

    private func toolCallStub(_ name: String, _ arguments: String, id: String = "c1")
        -> MockTransport.Stub {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return .json("""
        {"choices":[{"message":{"content":null,"tool_calls":[
          {"id":"\(id)","type":"function",
           "function":{"name":"\(name)","arguments":"\(escaped)"}}]}}]}
        """)
    }

    private func agent(_ transport: MockTransport, tools: [any AgentTool], maxSteps: Int = 5)
        -> Agent {
        Agent(
            client: .test(transport: transport), model: "m", tools: tools, maxSteps: maxSteps
        )
    }

    func testAnAnswerWithNoToolsReturnsImmediately() async throws {
        let transport = MockTransport(stubs: [.completion("€0.26 per kWh.")])
        let outcome = try await agent(transport, tools: [StubTool(name: "search_web")])
            .run(messages: [.user("rate?")])

        XCTAssertEqual(outcome.text, "€0.26 per kWh.")
        XCTAssertTrue(outcome.steps.isEmpty)
        XCTAssertEqual(transport.requestCount, 1)
    }

    /// The behaviour the fixed pipeline could not have: search, read, answer.
    func testItRunsToolsThenAnswers() async throws {
        let transport = MockTransport(stubs: [
            toolCallStub("search_web", #"{"query":"stroomprijs 2026"}"#),
            toolCallStub("read_page", #"{"url":"https://acm.nl/tarieven"}"#, id: "c2"),
            .completion("ACM puts it at €0.24 per kWh for 2026."),
        ])

        let outcome = try await agent(transport, tools: [
            StubTool(name: "search_web", reply: "- ACM tarieven\n  https://acm.nl/tarieven"),
            StubTool(name: "read_page", reply: "Stroom 2026: €0,24 per kWh"),
        ]).run(messages: [.user("is that a good rate?")])

        XCTAssertEqual(outcome.text, "ACM puts it at €0.24 per kWh for 2026.")
        XCTAssertEqual(outcome.steps.map(\.tool), ["search_web", "read_page"])
        XCTAssertFalse(outcome.hitStepLimit)
        XCTAssertEqual(transport.requestCount, 3)
    }

    /// The model's own turn has to be replayed before its results, or the
    /// tool messages are orphans and the next request is rejected.
    func testTheAssistantTurnIsReplayedBeforeTheToolResult() async throws {
        let transport = MockTransport(stubs: [
            toolCallStub("search_web", #"{"query":"x"}"#),
            .completion("done"),
        ])
        _ = try await agent(transport, tools: [StubTool(name: "search_web")])
            .run(messages: [.user("q")])

        let second = try XCTUnwrap(transport.requests.last?.body)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: second) as? [String: Any]
        )
        let roles = try XCTUnwrap(object["messages"] as? [[String: Any]])
            .compactMap { $0["role"] as? String }
        XCTAssertEqual(roles, ["user", "assistant", "tool"])
    }

    func testAFailingToolIsHandedBackRatherThanEndingTheRun() async throws {
        let transport = MockTransport(stubs: [
            toolCallStub("search_web", #"{"query":"x"}"#),
            .completion("Answered without the search."),
        ])
        let outcome = try await agent(transport, tools: [
            StubTool(name: "search_web", shouldThrow: true)
        ]).run(messages: [.user("q")])

        XCTAssertEqual(outcome.text, "Answered without the search.")
        XCTAssertEqual(outcome.steps.count, 1)
        XCTAssertTrue(outcome.steps[0].failed)

        let body = String(decoding: transport.requests.last?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("Failed:"), "the model must be told, so it can adapt")
    }

    func testAnUnknownToolNamesTheOnesThatExist() async throws {
        let transport = MockTransport(stubs: [
            toolCallStub("browse_everything", "{}"),
            .completion("fine"),
        ])
        let outcome = try await agent(transport, tools: [StubTool(name: "search_web")])
            .run(messages: [.user("q")])

        XCTAssertTrue(outcome.steps[0].failed)
        let body = String(decoding: transport.requests.last?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("search_web"), "name what it does have")
    }

    /// A loop that spends its budget and returns nothing is worse than one
    /// that never ran.
    func testRunningOutOfStepsStillProducesAnAnswer() async throws {
        let stubs = (0..<3).map { toolCallStub("search_web", #"{"query":"x"}"#, id: "c\($0)") }
            + [.completion("Here is what I found, though I could not confirm the 2026 figure.")]
        let transport = MockTransport(stubs: stubs)

        let outcome = try await agent(
            transport, tools: [StubTool(name: "search_web")], maxSteps: 3
        ).run(messages: [.user("q")])

        XCTAssertTrue(outcome.hitStepLimit)
        XCTAssertTrue(outcome.text.contains("could not confirm"))

        let body = String(decoding: transport.requests.last?.body ?? Data(), as: UTF8.self)
        XCTAssertFalse(
            body.contains("\"tools\""),
            "the final call must offer no tools, or it searches again instead of answering"
        )
    }

    func testStepsSummarizeWhatWasAskedFor() {
        XCTAssertEqual(Agent.summarize(#"{"query":"stroomprijs 2026"}"#), "stroomprijs 2026")
        XCTAssertEqual(Agent.summarize(#"{"url":"https://acm.nl"}"#), "https://acm.nl")
        XCTAssertEqual(Agent.summarize("not json"), "")
    }
}

/// A loop that works in silence for fifteen seconds reads as one that has
/// hung. The callback is what the interface has to show instead.
final class AgentProgressTests: XCTestCase {

    func testEveryStepIsReportedAsItHappens() async throws {
        func toolCall(_ name: String, id: String) -> MockTransport.Stub {
            .json("""
            {"choices":[{"message":{"content":null,"tool_calls":[
              {"id":"\(id)","type":"function",
               "function":{"name":"\(name)","arguments":"{\\"query\\":\\"x\\"}"}}]}}]}
            """)
        }

        let transport = MockTransport(stubs: [
            toolCall("search_web", id: "c1"),
            toolCall("read_page", id: "c2"),
            .completion("done"),
        ])

        let collector = StepCollector()
        let agent = Agent(
            client: .test(transport: transport),
            model: "m",
            tools: [StubTool(name: "search_web"), StubTool(name: "read_page")]
        )

        let outcome = try await agent.run(messages: [.user("q")]) { step in
            await collector.add(step)
        }

        let reported = await collector.steps
        XCTAssertEqual(reported.map(\.tool), ["search_web", "read_page"])
        XCTAssertEqual(
            reported.map(\.tool), outcome.steps.map(\.tool),
            "what was shown live and what is kept must be the same trail"
        )
    }

    func testAFailedStepIsReportedToo() async throws {
        let transport = MockTransport(stubs: [
            .json("""
            {"choices":[{"message":{"content":null,"tool_calls":[
              {"id":"c1","type":"function",
               "function":{"name":"search_web","arguments":"{}"}}]}}]}
            """),
            .completion("done"),
        ])

        let collector = StepCollector()
        _ = try await Agent(
            client: .test(transport: transport),
            model: "m",
            tools: [StubTool(name: "search_web", shouldThrow: true)]
        ).run(messages: [.user("q")]) { await collector.add($0) }

        let reported = await collector.steps
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].failed, "a silent failure is the worst kind")
    }

    func testTheCallbackIsOptional() async throws {
        let transport = MockTransport(stubs: [.completion("straight answer")])
        let outcome = try await Agent(
            client: .test(transport: transport), model: "m", tools: []
        ).run(messages: [.user("q")])
        XCTAssertEqual(outcome.text, "straight answer")
    }
}

private actor StepCollector {
    var steps: [AgentStep] = []
    func add(_ step: AgentStep) { steps.append(step) }
}
