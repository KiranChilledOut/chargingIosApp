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

    public init(
        client: NebiusClient,
        cache: TranslationCache?,
        settings: AppSettings,
        textModel: String
    ) {
        self.client = client
        self.cache = cache
        self.settings = settings
        self.textModel = textModel
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
