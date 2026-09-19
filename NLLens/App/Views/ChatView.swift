import SwiftUI
import NLLensCore

/// Ask about the screen you just captured.
///
/// Laid out asymmetrically on purpose. Questions are short and belong to the
/// reader, so they sit right in a tinted bubble. Answers are the substance —
/// often two or three sentences with a Dutch phrase quoted inside — so they
/// run full width as plain text against a rule, where they read like prose
/// rather than like chat. Symmetric bubbles would cost line length exactly
/// where it is most needed.
struct ChatView: View {

    @ObservedObject var session: ChatSession
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if session.isEmpty {
                        opener
                    } else {
                        ForEach(session.messages) { message in
                            row(for: message).id(message.id)
                        }
                    }

                    if session.isAnswering {
                        thinking.id(Self.thinkingAnchor)
                    }

                    if let error = session.errorMessage {
                        failure(error)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.s)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) { _, _ in
                scrollToEnd(proxy)
            }
            .onChange(of: session.isAnswering) { _, _ in
                scrollToEnd(proxy)
            }
        }
        .background(Theme.Palette.page)
        .safeAreaInset(edge: .bottom) { composer }
    }

    private static let thinkingAnchor = "thinking"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.Motion.settle) {
            if session.isAnswering {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = session.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private func row(for message: ConversationMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: Theme.Space.xxl)
                Text(message.text)
                    .font(Theme.Typeface.reading)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .background(
                        Theme.Palette.accent.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.large)
                    )
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Capsule()
                    .fill(Theme.Palette.accent.opacity(0.35))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(message.text)
                        .font(Theme.Typeface.reading)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let found = session.sources[message.id], !found.isEmpty {
                        sourceList(found)
                    }
                }
            }
        }
    }

    /// Where an answer was checked. Worth the space: a figure about rates or
    /// thresholds is only as good as its date, and this is what lets the
    /// reader go and look.
    private func sourceList(_ found: [WebSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label("Checked against", systemImage: "globe")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)

            ForEach(found) { result in
                if let url = URL(string: result.url) {
                    Link(destination: url) {
                        Text(result.title)
                            .font(Theme.Typeface.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
        )
    }

    private var thinking: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text(session.isSearching ? "Looking it up…" : "Thinking…")
                .font(Theme.Typeface.detail)
                .foregroundStyle(.secondary)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typeface.detail)
                .foregroundStyle(.orange)
            Button("Try again") {
                Task { await session.retry() }
            }
            .font(Theme.Typeface.detail)
        }
        .cardSurface()
    }

    // MARK: - Opening state

    private var opener: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Ask about this screen")
                .font(Theme.Typeface.title)

            Text("It can see what you captured. If the answer depends on your situation, it will ask before answering.")
                .font(Theme.Typeface.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(session.suggestedQuestions, id: \.self) { question in
                    Button {
                        Task { await session.send(question) }
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Text(question)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .font(Theme.Typeface.detail)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Theme.Palette.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Theme.Space.xs)
        }
        .padding(.top, Theme.Space.l)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            TextField("Ask a question", text: $session.draft, axis: .vertical)
                .font(Theme.Typeface.reading)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .background(
                    Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large)
                )
                .submitLabel(.send)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        canSend ? Theme.Palette.accent : Theme.Palette.surface,
                        in: Circle()
                    )
            }
            .disabled(!canSend)
            .animation(Theme.Motion.quick, value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, Theme.Space.m)
        .background(.bar)
    }

    private var canSend: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.isAnswering
    }

    private func send() {
        guard canSend else { return }
        let text = session.draft
        Task { await session.send(text) }
    }
}
