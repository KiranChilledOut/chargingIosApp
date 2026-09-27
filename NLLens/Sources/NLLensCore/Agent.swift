import Foundation

/// Something the model can ask to have run.
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    /// `arguments` is raw JSON exactly as the model wrote it. A tool decodes
    /// its own, and reports its own failure as a result rather than throwing:
    /// a model that mis-called a tool can correct itself if it is told how,
    /// and cannot if the loop dies.
    func run(arguments: String) async throws -> String
}

/// One thing the agent did, for the interface to show.
///
/// Without this the loop is a black box that takes fifteen seconds. Showing
/// "searched… read acm.nl… searched again" is the difference between waiting
/// and wondering whether it has hung.
public struct AgentStep: Sendable, Equatable {
    public let tool: String
    public let detail: String
    public let failed: Bool

    public init(tool: String, detail: String, failed: Bool = false) {
        self.tool = tool
        self.detail = detail
        self.failed = failed
    }
}

public struct AgentOutcome: Sendable {
    public let text: String
    public let steps: [AgentStep]
    public let sources: [WebSearchResult]
    /// True when the loop ran out of steps and had to be told to answer.
    public let hitStepLimit: Bool
}

/// Collects what the tools found, so the answer can cite it.
public actor SourceLog {
    private var results: [WebSearchResult] = []
    private var seen = Set<String>()

    public init() {}

    public func add(_ incoming: [WebSearchResult]) {
        for result in incoming where seen.insert(result.url).inserted {
            results.append(result)
        }
    }

    public var all: [WebSearchResult] { results }
}

/// Runs the model with tools until it has an answer.
///
/// The fixed pipeline it replaces could only ever be as good as one search:
/// plan a query, run it, answer from whatever came back. When the results were
/// wrong — and they were, returning Dutch travel requirements for a question
/// about energy tariffs — it answered anyway and said it could not find the
/// figure. It had no way to notice, and no way to try again.
///
/// A loop can. It can search, open the page, see the figure is for the wrong
/// year, search again, and only then answer.
public struct Agent: Sendable {

    private let client: NebiusClient
    private let model: String
    private let tools: [any AgentTool]
    private let maxSteps: Int
    private let maxTokens: Int

    public init(
        client: NebiusClient,
        model: String,
        tools: [any AgentTool],
        maxSteps: Int = 5,
        maxTokens: Int = 3000
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
    }

    /// - Parameter onStep: called as each tool finishes, so the interface can
    ///   say what is happening. Without it the loop is fifteen silent seconds,
    ///   which reads as a hang rather than as work.
    public func run(
        messages: [ChatMessage],
        onStep: (@Sendable (AgentStep) async -> Void)? = nil
    ) async throws -> AgentOutcome {
        var conversation = messages
        var steps: [AgentStep] = []
        let definitions = tools.map(\.definition)
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.name, $0) })

        for _ in 0..<maxSteps {
            let turn = try await client.turn(
                messages: conversation,
                model: model,
                tools: definitions,
                temperature: 0.3,
                maxTokens: maxTokens
            )

            guard turn.wantsTools else {
                return AgentOutcome(
                    text: turn.text, steps: steps, sources: [], hitStepLimit: false
                )
            }

            // The model's own turn has to go back in before its results, or
            // the tool messages are orphans and the request is rejected.
            conversation.append(.assistant(turn))

            for call in turn.toolCalls {
                guard let tool = byName[call.name] else {
                    // Naming the tools it does have turns a dead end into a
                    // correctable mistake.
                    let available = definitions.map(\.name).joined(separator: ", ")
                    let step = AgentStep(
                        tool: call.name, detail: "no such tool", failed: true
                    )
                    steps.append(step)
                    await onStep?(step)
                    conversation.append(.toolResult(
                        callID: call.id, name: call.name,
                        content: "No tool called \(call.name). Available: \(available)."
                    ))
                    continue
                }

                do {
                    let result = try await tool.run(arguments: call.arguments)
                    let step = AgentStep(
                        tool: call.name, detail: Self.summarize(call.arguments)
                    )
                    steps.append(step)
                    await onStep?(step)
                    conversation.append(.toolResult(
                        callID: call.id, name: call.name, content: result
                    ))
                } catch {
                    // Handed back rather than thrown. One failing search is
                    // not a failed answer, and the model can try another.
                    let reason = FailureText.describe(error)
                    let step = AgentStep(tool: call.name, detail: reason, failed: true)
                    steps.append(step)
                    await onStep?(step)
                    conversation.append(.toolResult(
                        callID: call.id, name: call.name, content: "Failed: \(reason)"
                    ))
                }
            }
        }

        // Out of steps. Ask once more with no tools, so it has to answer from
        // what it gathered — otherwise a loop that spent five searches returns
        // nothing at all, which is the worst of both.
        let final = try await client.turn(
            messages: conversation + [.user(
                "Stop searching and answer now with what you have. "
                    + "Say plainly which part you could not confirm."
            )],
            model: model,
            tools: [],
            temperature: 0.3,
            maxTokens: maxTokens
        )
        return AgentOutcome(
            text: final.text, steps: steps, sources: [], hitStepLimit: true
        )
    }

    /// A tool call's arguments, short enough for a status line.
    static func summarize(_ arguments: String, limit: Int = 60) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        // The first string value is the query or the URL — the part worth
        // showing. Key order is not preserved through JSONSerialization, so
        // the known names are checked first.
        for key in ["query", "url", "topic"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value.count > limit ? String(value.prefix(limit)) + "…" : value
            }
        }
        return ""
    }
}
