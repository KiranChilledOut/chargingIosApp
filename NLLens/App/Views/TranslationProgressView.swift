import SwiftUI

/// Shown while a multi-capture batch translates.
struct TranslationProgressView: View {
    let progress: OverlayPresenter.Progress

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)

            Text(
                progress.total <= 1
                    ? "Translating…"
                    : "Translating screen \(min(progress.completed + 1, progress.total)) of \(progress.total)"
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .animation(.easeInOut, value: progress)
    }
}

/// Shown when a share-sheet translation fails, which has no intent dialog to
/// report through.
struct TranslationFailureView: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Button("Close", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
