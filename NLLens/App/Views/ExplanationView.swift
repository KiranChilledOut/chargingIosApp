import SwiftUI
import NLLensCore

/// What the screen is asking, rather than what it says.
///
/// This is the half a dictionary cannot do. Facing a Dutch form, a literal
/// rendering of every label still leaves you not knowing which field wants
/// your BSN, that a box is pre-ticked, or that agreeing renews something
/// monthly. Warnings lead for that reason — the costly thing is the thing you
/// would otherwise scroll past.
struct ExplanationView: View {

    let explanation: ScreenExplanation
    let isLoading: Bool
    let errorMessage: String?
    var onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isLoading {
                    loading
                } else if let errorMessage {
                    failure(errorMessage)
                } else if explanation.isEmpty {
                    ContentUnavailableView(
                        "Nothing to explain",
                        systemImage: "questionmark.bubble",
                        description: Text("The model could not make sense of this screen.")
                    )
                } else {
                    content
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading the screen…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if !explanation.summary.isEmpty {
            Text(explanation.summary)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }

        // Warnings before actions: the point is to see the cost before you
        // start following the steps that commit you to it.
        if !explanation.warnings.isEmpty {
            section("Watch out", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                ForEach(Array(explanation.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if !explanation.actions.isEmpty {
            section("What to do", systemImage: "list.number", tint: .accentColor) {
                ForEach(Array(explanation.actions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(action)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        Text("An explanation is a reading of the screen, not legal or financial advice. Check anything that costs money.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
