import SwiftUI

@main
struct NLLensApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var selection = Tab.screen
    @StateObject private var presenter = OverlayPresenter.shared

    enum Tab: Hashable {
        case screen, write, glossary, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            ReviewView()
                .tabItem { Label("Screen", systemImage: "text.viewfinder") }
                .tag(Tab.screen)

            ComposeView()
                .tabItem { Label("Write", systemImage: "pencil.and.outline") }
                .tag(Tab.write)

            GlossaryView()
                .tabItem { Label("Glossary", systemImage: "character.book.closed") }
                .tag(Tab.glossary)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Presented when the full-size intent hands over a freshly translated
        // screen. Sits on the TabView so it covers whichever tab is showing.
        .fullScreenCover(isPresented: isPresentingOverlay) {
            if let snapshot = presenter.pending {
                OverlayViewerView(snapshot: snapshot) {
                    presenter.dismiss()
                }
            }
        }
    }

    private var isPresentingOverlay: Binding<Bool> {
        Binding(
            get: { presenter.pending != nil },
            set: { presenting in
                if !presenting { presenter.dismiss() }
            }
        )
    }
}
