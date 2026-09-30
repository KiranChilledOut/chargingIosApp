import SwiftUI
import Combine
import NLLensCore

/// Drives one conversation about a captured screen.
@MainActor
final class ChatSession: ObservableObject {

    @Published private(set) var conversation: ScreenConversation
    @Published private(set) var isAnswering = false
    @Published var errorMessage: String?
    @Published var draft = ""
    /// What each answer was checked against, so the reader can follow it up.
    @Published private(set) var sources: [UUID: [WebSearchResult]] = [:]
    /// Anything worth saying about a lookup — no key, or it failed.
    @Published private(set) var notes: [UUID: String] = [:]
    /// Said when a backup model answered. Silent fallback is worse than none:
    /// the reply reads differently and nothing explains why.
    @Published private(set) var fallbackNotes: [UUID: String] = [:]

    /// Look up for the next message regardless of the setting.
    @Published var forceSearch = false
    /// Let the model search, read pages and search again for the next
    /// message, rather than answering from one lookup.
    @Published var deepResearch = false
    /// What the agent is doing, while it is doing it. A loop that takes
    /// fifteen seconds in silence reads as one that has hung.
    @Published private(set) var liveSteps: [AgentStep] = []
    /// What it did, kept against the answer it produced.
    @Published private(set) var steps: [UUID: [AgentStep]] = [:]
    /// Overrides the configured model for this conversation only.
    @Published var modelOverride: String?

    private let environment: AppEnvironment

    init(snapshot: LastResultStore.Snapshot, environment: AppEnvironment = .shared) {
        self.environment = environment

        // The screen's English text is the grounding, and the Dutch behind it
        // is what the term index is matched against — terms have to be found
        // in the original, not the translation.
        let english = snapshot.pairs.map(\.translatedText).joined(separator: "\n")
        let dutch = snapshot.pairs.map(\.sourceText).joined(separator: "\n")

        conversation = ScreenConversation(
            screenText: english,
            termGrounding: DutchTermIndex.grounding(for: dutch)
        )
    }

    var messages: [ConversationMessage] { conversation.messages }

    /// True while a lookup may be running, so the wait can be explained rather
    /// than just being longer than usual.
    var isSearching: Bool {
        isAnswering && environment.hasSearchKey
            && (forceSearch || deepResearch || environment.settings.webSearchEnabled)
    }

    /// Whether digging deeper is available at all. Without a search key there
    /// is nothing for a loop to do that one call does not already do.
    var canResearch: Bool { environment.hasSearchKey }

    /// The model this conversation will actually use.
    var activeModel: String { modelOverride ?? environment.textModel }

    /// The override as a chain, keeping the configured backups.
    ///
    /// Picking a model for one conversation is a preference about the
    /// *primary*, not a request to give up resilience — so the backups still
    /// apply behind it.
    private var overrideChain: ModelChain? {
        modelOverride.map { ModelChain(primary: $0, backups: environment.textBackups) }
    }

    /// Short name for the picker — the vendor prefix is noise in a menu.
    var activeModelLabel: String {
        activeModel.split(separator: "/").last.map(String.init) ?? activeModel
    }
    var isEmpty: Bool { conversation.isEmpty }

    /// Terms found on this screen, offered as openers so the first question
    /// costs no typing.
    var suggestedQuestions: [String] {
        var prompts = ["What is this screen asking me to do?"]

        let terms = DutchTermIndex.matches(in: conversation.termGrounding, limit: 2)
        prompts.append(contentsOf: terms.map { "What does \($0.term) mean?" })

        prompts.append("Which option should I choose?")
        return Array(prompts.prefix(4))
    }

    /// Records a vision model's reading so later turns inherit it without
    /// re-sending the image.
    func adopt(explanation: ScreenExplanation) {
        guard !explanation.isEmpty else { return }
        var parts = [explanation.summary]
        if !explanation.actions.isEmpty {
            parts.append("Steps: " + explanation.actions.joined(separator: "; "))
        }
        if !explanation.warnings.isEmpty {
            parts.append("Watch out: " + explanation.warnings.joined(separator: "; "))
        }
        conversation.visualReading = parts.joined(separator: "\n")
    }

    func send(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }

        draft = ""
        errorMessage = nil
        conversation.append(role: .user, text: question)
        isAnswering = true
        defer { isAnswering = false }

        let digging = deepResearch && canResearch
        liveSteps = []

        do {
            let pipeline = await environment.pipeline()
            let answer = digging
                ? try await pipeline.research(in: conversation, model: overrideChain) { step in
                    await MainActor.run { self.liveSteps.append(step) }
                }
                : try await pipeline.answer(
                    in: conversation,
                    forceSearch: forceSearch,
                    model: overrideChain
                )
            conversation.append(role: .assistant, text: answer.text)

            if let id = conversation.messages.last?.id {
                if !answer.sources.isEmpty { sources[id] = answer.sources }
                notes[id] = answer.searchStatus.note
                if !answer.steps.isEmpty { steps[id] = answer.steps }
                if let note = Self.fallbackNote(for: answer) { fallbackNotes[id] = note }
            }
            // One-shot, like the paperclip in a mail client: forcing a lookup
            // is a decision about this question, not about the conversation.
            forceSearch = false
            deepResearch = false
            liveSteps = []
        } catch {
            liveSteps = []
            // Drop the question rather than leave it sitting in the history
            // looking answered, and put it back in the field so it is not lost.
            conversation.removeLast()
            draft = question
            errorMessage = Self.message(for: error)
        }
    }

    /// Names the model that answered, and the one that could not.
    static func fallbackNote(for answer: TranslationPipeline.Answer) -> String? {
        guard let failed = answer.skippedModels.first else { return nil }

        let shortName: (String) -> String = { $0.split(separator: "/").last.map(String.init) ?? $0 }
        return "\(shortName(failed.model)) failed, so \(shortName(answer.modelUsed)) "
            + "answered instead — \(failed.reason)"
    }

    /// Re-asks the last question after a failure.
    func retry() async {
        guard !draft.isEmpty else { return }
        await send(draft)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? NebiusError { return error.userMessage }
        if case PipelineError.cloudDisabled = error {
            return "Cloud is off. Turn it on in Settings to ask questions."
        }
        return error.localizedDescription
    }
}
