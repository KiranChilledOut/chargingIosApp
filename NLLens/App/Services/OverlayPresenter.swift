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

    /// Non-nil while a translated screen is waiting to be shown full screen.
    @Published var pending: LastResultStore.Snapshot?

    private init() {}

    @MainActor
    func present(_ snapshot: LastResultStore.Snapshot) {
        pending = snapshot
    }

    @MainActor
    func dismiss() {
        pending = nil
    }

    /// Entry point for the intent, which is not already on the main actor.
    static func presentFromBackground(_ snapshot: LastResultStore.Snapshot) {
        Task { @MainActor in
            shared.present(snapshot)
        }
    }
}
