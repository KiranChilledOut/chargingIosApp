import Foundation

/// What a translate run produced, plus enough detail to show the user what it
/// cost and where the answer came from.
public struct TranslationOutcome: Sendable {
    public var blocks: [TranslatedBlock]
    public var cacheHits: Int
    public var networkBlocks: Int
    public var redactedCount: Int
    public var redactedKinds: Set<RedactionSpan.Kind>
    /// True when nothing left the device.
    public var servedEntirelyFromCache: Bool

    public init(
        blocks: [TranslatedBlock],
        cacheHits: Int = 0,
        networkBlocks: Int = 0,
        redactedCount: Int = 0,
        redactedKinds: Set<RedactionSpan.Kind> = [],
        servedEntirelyFromCache: Bool = false
    ) {
        self.blocks = blocks
        self.cacheHits = cacheHits
        self.networkBlocks = networkBlocks
        self.redactedCount = redactedCount
        self.redactedKinds = redactedKinds
        self.servedEntirelyFromCache = servedEntirelyFromCache
    }
}

public enum PipelineError: Swift.Error, Equatable {
    case cloudDisabled
    case nothingToTranslate
}

/// Orchestrates OCR output into translated blocks.
public struct TranslationPipeline: Sendable {

    /// Blocks per request.
    ///
    /// Kept well below what the context could hold, because the *output* is
    /// the binding constraint, not the input: every run comes back as repaired
    /// Dutch and English both, so a screen of prose needs several times its
    /// own length in reply. Too large a batch is truncated mid-array and the
    /// whole request is wasted.
    public static let batchSize = 20

    private let client: NebiusClient
    private let cache: TranslationCache?
    private let settings: AppSettings
    private let textModel: String
    private let search: TavilyClient?
    private let memory: MemoryStore?

    public init(
        client: NebiusClient,
        cache: TranslationCache?,
        settings: AppSettings,
        textModel: String,
        search: TavilyClient? = nil,
        memory: MemoryStore? = nil
    ) {
        self.client = client
        self.cache = cache
        self.settings = settings
        self.textModel = textModel
        self.search = search
        self.memory = memory
    }

    // MARK: - Translate

    public func translate(blocks rawBlocks: [TextBlock]) async throws -> TranslationOutcome {
        // Runs with no translatable content — prices, times, bare numbers —
        // pass straight through. Sending them wastes tokens and tempts the
        // model into "correcting" numbers.
        let grouped = BlockGrouping.group(rawBlocks)
        let translatable = grouped.filter { TextNormalization.isTranslatable($0.text) }
        let passthrough = grouped.filter { !TextNormalization.isTranslatable($0.text) }

        guard !translatable.isEmpty else {
            guard !passthrough.isEmpty else { throw PipelineError.nothingToTranslate }
            return TranslationOutcome(
                blocks: passthrough.map {
                    TranslatedBlock(
                        id: $0.id, sourceText: $0.text,
                        translatedText: $0.text, box: $0.box, fromCache: true
                    )
                },
                servedEntirelyFromCache: true
            )
        }

        // Cache first.
        var hits: [Int: CacheEntry] = [:]
        var misses = translatable
        if settings.cacheEnabled, let cache {
            let partitioned = await cache.partition(blocks: translatable)
            hits = partitioned.hits
            misses = partitioned.misses
        }

        var results: [Int: TranslatedBlock] = [:]
        for block in translatable {
            if let entry = hits[block.id] {
                results[block.id] = TranslatedBlock(
                    id: block.id, sourceText: entry.nl,
                    translatedText: entry.en, box: block.box, fromCache: true
                )
            }
        }

        var redactedCount = 0
        var redactedKinds: Set<RedactionSpan.Kind> = []

        if !misses.isEmpty {
            guard settings.cloudEnabled else { throw PipelineError.cloudDisabled }

            for batch in misses.chunked(into: Self.batchSize) {
                let (safeBlocks, map) = Redactor.redact(
                    blocks: batch, policy: settings.redactionPolicy
                )
                redactedCount += map.count
                redactedKinds.formUnion(map.kindsFound)

                let units = try await requestTranslation(for: safeBlocks)
                var byID = Dictionary(
                    units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
                )

                // Models quietly drop entries from long lists — more so the
                // longer the list — and the fallback below would render those
                // runs as untranslated Dutch. Asking again for just the
                // omitted ones recovers most of them, and a short list is
                // exactly the case models get right.
                let omitted = safeBlocks.filter { byID[$0.id] == nil }
                if !omitted.isEmpty,
                   let recovered = try? await requestTranslation(for: omitted) {
                    for unit in recovered where byID[unit.id] == nil {
                        byID[unit.id] = unit
                    }
                }

                for block in batch {
                    // A model that skipped or renumbered an entry must not
                    // silently blank the screen: fall back to source text.
                    guard let unit = byID[block.id] else {
                        results[block.id] = TranslatedBlock(
                            id: block.id, sourceText: block.text,
                            translatedText: block.text, box: block.box
                        )
                        continue
                    }
                    let nl = map.restore(in: unit.nl)
                    let en = map.restore(in: unit.en)
                    results[block.id] = TranslatedBlock(
                        id: block.id, sourceText: nl,
                        translatedText: en, box: block.box
                    )
                }
            }
        }

        for block in passthrough {
            results[block.id] = TranslatedBlock(
                id: block.id, sourceText: block.text,
                translatedText: block.text, box: block.box, fromCache: true
            )
        }

        let ordered = grouped.compactMap { results[$0.id] }

        if settings.cacheEnabled, let cache {
            await cache.store(blocks: ordered.filter { !$0.fromCache })
            _ = try? await cache.flush()
        }

        return TranslationOutcome(
            blocks: ordered,
            cacheHits: hits.count,
            networkBlocks: misses.count,
            redactedCount: redactedCount,
            redactedKinds: redactedKinds,
            servedEntirelyFromCache: misses.isEmpty
        )
    }

    private func requestTranslation(for blocks: [TextBlock]) async throws -> [TranslationUnit] {
        let raw = try await client.complete(
            messages: [
                .system(Prompts.translateSystem),
                .user(Prompts.translateUserMessage(blocks: blocks)),
            ],
            model: textModel,
            temperature: 0.1,
            maxTokens: 8192,
            responseFormat: .jsonSchema(Schemas.translationUnits)
        )
        return try JSONExtraction.decode([TranslationUnit].self, from: raw)
    }

    // MARK: - Explain

    public func explain(
        imageBase64: String,
        mimeType: String = "image/jpeg",
        visionModel: String
    ) async throws -> ScreenExplanation {
        guard settings.cloudEnabled else { throw PipelineError.cloudDisabled }

        let raw = try await client.complete(
            messages: [
                .system(Prompts.explainSystem),
                ChatMessage(role: .user, content: [
                    .imageBase64(imageBase64, mimeType: mimeType),
                    .text(Prompts.explainUserMessage),
                ]),
            ],
            model: visionModel,
            temperature: 0.2,
            maxTokens: 1024,
            responseFormat: .jsonSchema(Schemas.screenExplanation)
        )
        return try JSONExtraction.decode(ScreenExplanation.self, from: raw)
    }

    // MARK: - Chat

    /// Answers the next turn of a conversation about a captured screen.
    ///
    /// Everything the model sees goes through redaction first — the screen
    /// text, the visual reading and every message — under one shared
    /// namespace, so an IBAN that appears both on screen and in something the
    /// user typed maps to the same token rather than looking like two
    /// accounts. The reply is restored on the way back.
    /// A reply, plus whatever it was checked against.
    public struct Answer: Sendable {
        public let text: String
        public let sources: [WebSearchResult]
        public let searchStatus: SearchStatus

        public init(
            text: String,
            sources: [WebSearchResult] = [],
            searchStatus: SearchStatus = .skipped
        ) {
            self.text = text
            self.sources = sources
            self.searchStatus = searchStatus
        }
    }

    /// - Parameters:
    ///   - forceSearch: look up even when the setting is off. Wired to the
    ///     globe in the composer, for the turn where the user knows current
    ///     figures are what the answer turns on.
    ///   - model: overrides the configured text model for this turn only.
    public func answer(
        in conversation: ScreenConversation,
        forceSearch: Bool = false,
        model: String? = nil
    ) async throws -> Answer {
        guard settings.cloudEnabled else { throw PipelineError.cloudDisabled }

        let history = conversation.recentHistory()
        let (safe, map) = Redactor.redact(
            texts: [conversation.screenText, conversation.visualReading]
                + history.map(\.text),
            policy: settings.redactionPolicy
        )

        var safeConversation = conversation
        safeConversation.screenText = safe[0]
        safeConversation.visualReading = safe[1]
        safeConversation.messages = zip(history, safe.dropFirst(2)).map { message, text in
            var copy = message
            copy.text = text
            return copy
        }

        let question = safeConversation.messages.last?.text ?? ""

        // What is already known comes first: it shapes the search query as
        // much as it shapes the answer. Asking "is that a good rate?" is only
        // answerable against the rate they are already on.
        let recalled = await memory?.grounding(
            for: "\(question)\n\(safeConversation.visualReading)"
        ) ?? ""

        // Looked up before answering, not after, so the reply is built on
        // current figures rather than corrected against them.
        let (found, status) = await lookUp(
            question: question,
            conversation: safeConversation,
            memory: recalled,
            force: forceSearch,
            model: model ?? textModel
        )

        // The model is told the outcome either way. Handed an empty grounding
        // string and no explanation, it invents one — and what it invents is
        // that it has no search tool at all.
        let grounding = found?.grounding() ?? status.modelNote

        let raw = try await client.complete(
            messages: safeConversation.requestMessages(
                instructions: Prompts.chatSystem,
                searchGrounding: grounding,
                memory: recalled
            ),
            model: model ?? textModel,
            temperature: 0.3,
            // Generous, because the default text model reasons before
            // answering: at 900 the chain of thought consumed the whole budget
            // and `content` came back empty.
            maxTokens: 3000
        )
        let text = map.restore(in: raw)

        // Detached on purpose. Remembering is worth a round trip but not worth
        // making them wait for one: the answer is already composed, and
        // awaiting here would park a finished reply behind a call the user
        // never asked for. A failure to remember must not turn a good answer
        // into an error either.
        if memory != nil, settings.memoryEnabled {
            let conversationCopy = safeConversation
            let learningModel = model ?? textModel
            Task.detached(priority: .background) { [self] in
                await learn(
                    from: conversationCopy, question: question,
                    answer: raw, model: learningModel
                )
            }
        }

        return Answer(
            text: text,
            sources: found?.results ?? [],
            searchStatus: status
        )
    }

    // MARK: - Memory

    /// Records what this exchange revealed about the person.
    ///
    /// Runs on the redacted conversation, so anything sensitive is already a
    /// placeholder and `MemoryFact.isStorable` drops it. Errors are swallowed:
    /// this is a background courtesy, and a store that cannot write must not
    /// fail an answer that already succeeded.
    func learn(
        from conversation: ScreenConversation,
        question: String,
        answer: String,
        model: String
    ) async {
        guard let memory, settings.memoryEnabled, !question.isEmpty else { return }

        let digest = """
        Screen: \(conversation.visualReading)

        Screen text:
        \(String(conversation.screenText.prefix(1500)))

        They asked: \(question)
        You answered: \(String(answer.prefix(800)))
        """

        do {
            let raw = try await client.complete(
                messages: [.system(Prompts.memorySystem), .user(digest)],
                model: model,
                temperature: 0,
                maxTokens: 400,
                responseFormat: .jsonSchema(Schemas.memoryFacts)
            )
            // The screen's own one-line description is the most useful thing
            // to attribute a fact to later.
            let source = String(conversation.visualReading.prefix(80))
            let facts = Self.parseFacts(raw, source: source)
            guard !facts.isEmpty else { return }
            _ = try await memory.record(facts)
        } catch {
            // Deliberately silent. Nothing the user asked for has failed.
        }
    }

    struct FactsWire: Decodable {
        struct Entry: Decodable {
            let key: String
            let label: String?
            let value: String
        }
        let facts: [Entry]
    }

    static func parseFacts(_ raw: String, source: String = "") -> [MemoryFact] {
        guard let wire = try? JSONExtraction.decode(FactsWire.self, from: raw) else { return [] }

        return wire.facts.compactMap { entry in
            let fact = MemoryFact(
                key: entry.key,
                label: entry.label ?? "",
                value: entry.value,
                source: source
            )
            return fact.isStorable ? fact : nil
        }
    }

    /// Searches the web for the question at hand, reporting what happened.
    ///
    /// A failure never blocks the answer — grounding in the screen alone beats
    /// an error where an answer should be. But it is not silent either: the
    /// first version swallowed the outcome entirely, and a model politely
    /// explaining that it cannot search is indistinguishable from a search that
    /// ran and found nothing. The status is what tells them apart.
    private func lookUp(
        question: String,
        conversation: ScreenConversation,
        memory recalled: String,
        force: Bool,
        model: String
    ) async -> (WebSearchResponse?, SearchStatus) {
        guard force || settings.webSearchEnabled else { return (nil, .skipped) }
        guard let search, search.isUsable else { return (nil, .unavailable) }
        guard !question.isEmpty else { return (nil, .skipped) }

        let plan = await plan(
            question: question, conversation: conversation,
            memory: recalled, force: force, model: model
        )
        guard plan.isUsable else {
            return (nil, .notNeeded(plan.reason))
        }

        do {
            let response = try await search.search(plan.query)
            return (response, .searched(count: response.results.count))
        } catch let error as WebSearchError {
            return (nil, .failed(error.userMessage))
        } catch {
            return (nil, .failed(error.localizedDescription))
        }
    }

    /// Decides what to search for.
    ///
    /// The model writes the query, because only it can resolve what a
    /// follow-up refers to: "is that a good rate?" has to become a query about
    /// Dutch electricity prices per kWh, and nothing but the screen and the
    /// conversation can turn it into one. A heuristic query is built either
    /// way and used whenever the planning call fails or answers with
    /// something unusable — a lookup is too valuable to lose to a bad round
    /// trip.
    func plan(
        question: String,
        conversation: ScreenConversation,
        memory recalled: String,
        force: Bool,
        model: String
    ) async -> SearchPlan {
        let fallback = SearchQueryBuilder.fallbackQuery(
            question: question,
            screenText: conversation.screenText,
            visualReading: conversation.visualReading
        )

        let context = """
        Screen: \(conversation.visualReading)

        Screen text:
        \(String(conversation.screenText.prefix(1200)))

        \(recalled)

        Today: \(DateFormatter.searchStamp.string(from: Date()))
        Their question: \(question)
        """

        do {
            let raw = try await client.complete(
                messages: [.system(Prompts.searchPlanSystem), .user(context)],
                model: model,
                temperature: 0,
                maxTokens: 300,
                responseFormat: .jsonSchema(Schemas.searchPlan)
            )
            if let planned = Self.parsePlan(raw) {
                // The globe overrides a "no search needed": the user pressing
                // it is a statement that they want one.
                let needs = planned.needsSearch || force
                let query = SearchQueryBuilder.isAcceptable(planned.query)
                    ? planned.query
                    : fallback
                return SearchPlan(query: query, needsSearch: needs, reason: planned.reason)
            }
        } catch {
            // Fall through to the query built without asking.
        }
        return SearchPlan(query: fallback, needsSearch: true, reason: "")
    }

    /// Wire shape of a planning reply. `needs_search` and `reason` are
    /// optional on the way in: a planner that omitted a field should not turn
    /// the whole lookup off.
    struct PlanWire: Decodable {
        let query: String
        let needs_search: Bool?
        let reason: String?
    }

    static func parsePlan(_ raw: String) -> SearchPlan? {
        guard let wire = try? JSONExtraction.decode(PlanWire.self, from: raw) else { return nil }
        return SearchPlan(
            query: wire.query,
            needsSearch: wire.needs_search ?? true,
            reason: wire.reason ?? ""
        )
    }

    // MARK: - Risk

    /// Checks whether a screen is trying to defraud the person reading it.
    public func assessRisk(
        imageBase64: String,
        mimeType: String = "image/jpeg",
        visionModel: String
    ) async throws -> RiskAssessment {
        guard settings.cloudEnabled else { throw PipelineError.cloudDisabled }

        let raw = try await client.complete(
            messages: [
                .system(Prompts.riskSystem),
                ChatMessage(role: .user, content: [
                    .imageBase64(imageBase64, mimeType: mimeType),
                    .text(Prompts.riskUserMessage),
                ]),
            ],
            model: visionModel,
            temperature: 0.1,
            maxTokens: 700,
            responseFormat: .jsonSchema(Schemas.riskAssessment)
        )
        return try JSONExtraction.decode(RiskAssessment.self, from: raw)
    }

    // MARK: - Compose

    public func compose(
        english: String,
        register: Register
    ) async throws -> ComposeResult {
        guard settings.cloudEnabled else { throw PipelineError.cloudDisabled }

        let (safe, map) = Redactor.redact(text: english, policy: settings.redactionPolicy)
        let raw = try await client.complete(
            messages: [
                .system(Prompts.composeSystem(register: register)),
                .user(Prompts.composeUserMessage(english: safe)),
            ],
            model: textModel,
            temperature: 0.3,
            maxTokens: 1024,
            responseFormat: .jsonSchema(Schemas.composeResult)
        )
        var result = try JSONExtraction.decode(ComposeResult.self, from: raw)
        result.dutch = map.restore(in: result.dutch)
        result.notes = result.notes.map { map.restore(in: $0) }
        return result
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
