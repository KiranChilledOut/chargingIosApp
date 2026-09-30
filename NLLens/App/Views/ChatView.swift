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
    @StateObject private var catalog = ModelCatalog.shared
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

                    if let trail = session.steps[message.id], !trail.isEmpty {
                        StepTrail(steps: trail)
                    }
                    if let found = session.sources[message.id], !found.isEmpty {
                        sourceList(found)
                    }
                    if let note = session.notes[message.id] {
                        Label(note, systemImage: "globe.badge.chevron.backward")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = session.fallbackNotes[message.id] {
                        Label(note, systemImage: "arrow.triangle.branch")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text(waitingLabel)
                    .font(Theme.Typeface.detail)
                    .foregroundStyle(.secondary)
            }

            // Digging takes several round trips. Shown as it goes, because
            // fifteen silent seconds read as a hang rather than as work.
            ForEach(Array(session.liveSteps.enumerated()), id: \.offset) { _, step in
                StepRow(step: step)
            }
        }
    }

    private var waitingLabel: String {
        if session.deepResearch { return "Digging…" }
        return session.isSearching ? "Looking it up…" : "Thinking…"
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
        VStack(spacing: Theme.Space.s) {
            modelBar
            inputRow
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, Theme.Space.m)
        .background(.bar)
        .task { await catalog.loadIfNeeded() }
    }

    /// Which model is answering, changeable mid-conversation.
    private var modelBar: some View {
        HStack(spacing: Theme.Space.s) {
            Menu {
                if catalog.chatModels.isEmpty {
                    Button("Load models…") {
                        Task { await catalog.refresh() }
                    }
                } else {
                    Picker("Model", selection: $session.modelOverride) {
                        Text("Default (\(defaultModelLabel))").tag(String?.none)
                        ForEach(catalog.chatModels) { model in
                            Text(model.id).tag(String?.some(model.id))
                        }
                    }
                    Divider()
                    Button("Refresh list") {
                        Task { await catalog.refresh() }
                    }
                }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "cpu")
                    Text(session.activeModelLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if catalog.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var defaultModelLabel: String {
        AppEnvironment.shared.textModel
            .split(separator: "/").last.map(String.init) ?? "configured"
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            // Force a lookup for this question. One-shot, so it reads as a
            // decision about the question rather than a mode you forget is on.
            Button {
                session.forceSearch.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.headline)
                    .foregroundStyle(session.forceSearch ? Color.white : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        session.forceSearch ? Theme.Palette.accent : Theme.Palette.surface,
                        in: Circle()
                    )
            }
            .animation(Theme.Motion.quick, value: session.forceSearch)
            .accessibilityLabel(
                session.forceSearch ? "Web search on for this question" : "Search the web for this question"
            )

            // Digging costs several round trips, so it is asked for per
            // question rather than left on. Hidden without a search key,
            // because a loop with nothing to look things up in is just a
            // slower single call.
            if session.canResearch {
                Button {
                    session.deepResearch.toggle()
                } label: {
                    Image(systemName: "text.magnifyingglass")
                        .font(.headline)
                        .foregroundStyle(session.deepResearch ? Color.white : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(
                            session.deepResearch ? Theme.Palette.accent : Theme.Palette.surface,
                            in: Circle()
                        )
                }
                .animation(Theme.Motion.quick, value: session.deepResearch)
                .accessibilityLabel(
                    session.deepResearch
                        ? "Deep research on for this question"
                        : "Search, read the pages, and check before answering"
                )
            }

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

/// One thing the agent did.
private struct StepRow: View {
    let step: AgentStep

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: step.failed ? "xmark.circle" : icon)
                .font(.caption)
                .foregroundStyle(step.failed ? Color.orange : Color.secondary)
            Text(label)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var icon: String {
        switch step.tool {
        case "search_web": return "magnifyingglass"
        case "read_page": return "doc.text"
        case "recall": return "brain"
        default: return "wrench.and.screwdriver"
        }
    }

    private var label: String {
        let verb: String
        switch step.tool {
        case "search_web": verb = "Searched"
        case "read_page": verb = "Read"
        case "recall": verb = "Recalled"
        default: verb = step.tool
        }
        return step.detail.isEmpty ? verb : "\(verb) \(step.detail)"
    }
}

/// What the agent did, collapsed under a count.
///
/// Kept rather than discarded once the answer arrives: an answer that searched
/// four times and read two pages is worth more than one that guessed, and
/// there is no way to tell them apart from the text alone.
private struct StepTrail: View {
    let steps: [AgentStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                withAnimation(Theme.Motion.quick) { expanded.toggle() }
            } label: {
                Label(
                    summary,
                    systemImage: expanded ? "chevron.down" : "chevron.right"
                )
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    StepRow(step: step)
                        .padding(.leading, Theme.Space.m)
                }
            }
        }
    }

    private var summary: String {
        let searches = steps.filter { $0.tool == "search_web" }.count
        let reads = steps.filter { $0.tool == "read_page" }.count

        var parts: [String] = []
        if searches > 0 { parts.append("\(searches) search\(searches == 1 ? "" : "es")") }
        if reads > 0 { parts.append("\(reads) page\(reads == 1 ? "" : "s") read") }
        return parts.isEmpty ? "\(steps.count) steps" : parts.joined(separator: ", ")
    }
}
