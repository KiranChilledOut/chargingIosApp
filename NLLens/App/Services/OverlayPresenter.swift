import SwiftUI
import Combine
import NLLensCore

/// Carries a freshly translated screen from the intent to the full-screen
/// viewer.
///
/// An App Intent runs inside the app's own process, so a shared object is
/// enough — no URL scheme, no launch argument. It publishes rather than
/// storing a flag because the intent may finish either before or after the
/// SwiftUI scene exists; publishing means the view reacts whenever the value
/// lands, in either order.
///
/// The type itself is not `@MainActor` — that would make even reading
/// `.shared` from a `View`'s property initializer an isolation question. The
/// mutating entry points are, which is where it actually matters.
final class OverlayPresenter: ObservableObject {

    static let shared = OverlayPresenter()

    /// How far through a multi-capture run we are.
    struct Progress: Equatable {
        var completed: Int
        var total: Int

        var fraction: Double {
            total > 0 ? Double(completed) / Double(total) : 0
        }
    }

    /// Non-nil while a translated screen is waiting to be shown full screen.
    @Published var pending: LastResultStore.Snapshot?

    /// Non-nil while a batch is still being translated. The app is already in
    /// the foreground by then — `openAppWhenRun` brings it forward before the
    /// work starts — so without this it would sit on a blank tab for several
    /// seconds looking broken.
    @Published var progress: Progress?

    /// Set when a share-sheet translation failed. The intent paths report
    /// errors through their dialog; this one has no dialog to speak through.
    @Published var failure: String?

    private init() {}

    @MainActor
    func present(_ snapshot: LastResultStore.Snapshot) {
        progress = nil
        failure = nil
        pending = snapshot
    }

    @MainActor
    func dismiss() {
        pending = nil
        progress = nil
        failure = nil
    }

    /// True while a result, a progress indicator, or an error should be shown.
    var isActive: Bool { pending != nil || progress != nil || failure != nil }

    /// Entry points for the intent, which is not already on the main actor.
    static func presentFromBackground(_ snapshot: LastResultStore.Snapshot) {
        Task { @MainActor in
            shared.present(snapshot)
        }
    }

    static func reportProgress(completed: Int, total: Int) {
        Task { @MainActor in
            shared.progress = Progress(completed: completed, total: total)
        }
    }

    static func clearProgress() {
        Task { @MainActor in
            shared.progress = nil
        }
    }
}
