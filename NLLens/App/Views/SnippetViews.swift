import SwiftUI
import UIKit
import NLLensCore

/// Every intent result renders through this one view.
///
/// App Intents declare their snippet with an opaque `some View`, so all
/// branches of `perform()` must return the *same* concrete type. Modelling the
/// cases as data rather than as separate view structs is what makes the
/// success and failure paths returnable from the same function.
struct NLLensSnippetView: View {

    enum Content {
        case translation(image: UIImage, outcome: TranslationOutcome)
        case explanation(ScreenExplanation)
        case compose(ComposeResult)
        case message(title: String, message: String, symbol: String)
    }

    let content: Content

    static func message(_ title: String, _ message: String, symbol: String) -> NLLensSnippetView {
        NLLensSnippetView(content: .message(title: title, message: message, symbol: symbol))
    }

    var body: some View {
        Group {
            switch content {
            case .translation(let image, let outcome):
                TranslationBody(image: image, outcome: outcome)
            case .explanation(let explanation):
                ExplanationBody(explanation: explanation)
            case .compose(let result):
                ComposeBody(result: result)
            case .message(let title, let message, let symbol):
                MessageBody(title: title, message: message, symbol: symbol)
            }
        }
        .padding(12)
    }
}

/// Snippet shown over the foreground app after a translate run.
///
/// Snippets have little vertical room, so the rendered overlay leads and the
/// text pairs follow — the picture answers "what does this screen say" at a
/// glance, the list answers "what exactly did that word mean".
private struct TranslationBody: View {
    let image: UIImage
    let outcome: TranslationOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No height cap: a snippet is already a system-sized card, and
            // capping it again only shrinks the one thing worth reading. The
            // per-line Dutch/English list used to sit below this and cost the
            // image half the card — it lives in the app's Screen tab instead,
            // where there is room for it.
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))

            StatusFooter(outcome: outcome)
        }
    }
}

/// One line saying where the answer came from and whether anything was masked.
/// Worth the space: it is the only place the privacy behaviour is visible.
private struct StatusFooter: View {
    let outcome: TranslationOutcome

    var body: some View {
        HStack(spacing: 10) {
            if outcome.servedEntirelyFromCache {
                Label("Offline", systemImage: "bolt.fill")
            } else if outcome.cacheHits > 0 {
                Label("\(outcome.cacheHits) cached", systemImage: "bolt")
            }
            if outcome.redactedCount > 0 {
                Label("\(outcome.redactedCount) masked", systemImage: "lock.shield")
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct ExplanationBody: View {
    let explanation: ScreenExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(explanation.summary)
                .font(.headline)

            if !explanation.actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(explanation.actions.enumerated()), id: \.offset) { index, action in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(action)
                        }
                        .font(.callout)
                    }
                }
            }

            if !explanation.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(explanation.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct ComposeBody: View {
    let result: ComposeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.dutch)
                .font(.body)
                .textSelection(.enabled)

            Label("Copied to clipboard", systemImage: "doc.on.clipboard")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !result.notes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct MessageBody: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
