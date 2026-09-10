import SwiftUI

/// Shown while a multi-capture batch translates.
struct TranslationProgressView: View {
    let progress: OverlayPresenter.Progress

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)

            Text("Translating screen \(min(progress.completed + 1, progress.total)) of \(progress.total)")
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
