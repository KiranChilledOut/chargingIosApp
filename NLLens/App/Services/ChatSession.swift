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

        do {
            let pipeline = await environment.pipeline()
            let reply = try await pipeline.answer(in: conversation)
            conversation.append(role: .assistant, text: reply)
        } catch {
            // Drop the question rather than leave it sitting in the history
            // looking answered, and put it back in the field so it is not lost.
            conversation.removeLast()
            draft = question
            errorMessage = Self.message(for: error)
        }
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
