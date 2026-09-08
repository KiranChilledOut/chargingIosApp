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
    }
}
