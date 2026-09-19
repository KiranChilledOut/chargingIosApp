import Foundation

public struct ConversationMessage: Sendable, Equatable, Identifiable, Codable {
    public enum Role: String, Sendable, Codable {
        case user, assistant
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// A conversation about one captured screen.
///
/// The screen lives in the system message, not in the turns. That is the whole
/// trick for keeping this affordable: a vision model reads the screenshot once
/// to establish what it is, and every turn after that runs against the
/// translated text plus the term explanations — text-only, an order of
/// magnitude cheaper, and noticeably faster to answer.
public struct ScreenConversation: Sendable, Equatable, Codable {

    /// The screen's translated text, as the model's grounding.
    public var screenText: String
    /// What the Dutch terms on this screen actually mean, from `DutchTermIndex`.
    public var termGrounding: String
    /// A vision model's first reading of the screen, when one was taken.
    public var visualReading: String
    public var messages: [ConversationMessage]

    /// Budget for the replayed history, in characters.
    ///
    /// Characters rather than tokens because it needs no tokenizer and errs on
    /// the generous side for Dutch, whose long compounds tokenize worse than
    /// the character count suggests.
    public static let defaultHistoryBudget = 6000

    public init(
        screenText: String = "",
        termGrounding: String = "",
        visualReading: String = "",
        messages: [ConversationMessage] = []
    ) {
        self.screenText = screenText
        self.termGrounding = termGrounding
        self.visualReading = visualReading
        self.messages = messages
    }

    public var isEmpty: Bool { messages.isEmpty }

    public mutating func append(role: ConversationMessage.Role, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ConversationMessage(role: role, text: trimmed))
    }

    /// Removes the last message. Used when a request fails, so a question the
    /// model never answered does not sit in the history pretending it did.
    public mutating func removeLast() {
        guard !messages.isEmpty else { return }
        messages.removeLast()
    }

    // MARK: - Building a request

    /// The system message: who the model is, and everything known about the
    /// screen.
    public func systemMessage(
        instructions: String,
        searchGrounding: String = "",
        memory: String = ""
    ) -> String {
        var parts = [instructions]

        // Before the screen: what is already known is the frame the screen is
        // read against, not a footnote to it.
        if !memory.isEmpty {
            parts.append(memory)
        }
        if !searchGrounding.isEmpty {
            parts.append(searchGrounding)
        }

        if !visualReading.isEmpty {
            parts.append("What this screen appears to be:\n\(visualReading)")
        }
        if !termGrounding.isEmpty {
            parts.append(termGrounding)
        }
        if !screenText.isEmpty {
            parts.append("The screen's text, translated to English:\n\(screenText)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The full request: one system message carrying the screen, then as much
    /// recent history as the budget allows.
    public func requestMessages(
        instructions: String,
        searchGrounding: String = "",
        memory: String = "",
        historyBudget: Int = defaultHistoryBudget
    ) -> [ChatMessage] {
        var result: [ChatMessage] = [.system(
            systemMessage(
                instructions: instructions,
                searchGrounding: searchGrounding,
                memory: memory
            )
        )]

        for message in recentHistory(budget: historyBudget) {
            result.append(ChatMessage(
                role: message.role == .user ? .user : .assistant,
                content: [.text(message.text)]
            ))
        }
        return result
    }

    /// The newest messages that fit the budget, oldest first.
    ///
    /// Trimmed from the front: the last few turns are what the next answer
    /// depends on, and the screen itself — the part that must never be lost —
    /// is in the system message where trimming cannot reach it.
    ///
    /// The most recent message is always kept regardless of size, since
    /// dropping the question being asked would leave nothing to answer.
    public func recentHistory(budget: Int = defaultHistoryBudget) -> [ConversationMessage] {
        guard !messages.isEmpty else { return [] }

        var kept: [ConversationMessage] = []
        var used = 0

        for message in messages.reversed() {
            let cost = message.text.count
            if kept.isEmpty {
                kept.append(message)
                used = cost
                continue
            }
            guard used + cost <= budget else { break }
            kept.append(message)
            used += cost
        }
        return kept.reversed()
    }

    /// Whether history was dropped, so the UI can say so rather than letting
    /// the model appear to forget.
    public func isTrimmed(budget: Int = defaultHistoryBudget) -> Bool {
        recentHistory(budget: budget).count < messages.count
    }
}
