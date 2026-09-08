import SwiftUI
import NLLensCore

/// The accumulated translation memory, searchable and editable.
///
/// After a couple of weeks of ordinary use this is a personal dictionary of
/// exactly the apps you use — and every entry in it is one the app will serve
/// instantly, offline, and for free.
struct GlossaryView: View {

    @State private var entries: [CacheEntry] = []
    @State private var search = ""
    @State private var editing: CacheEntry?
    @State private var isLoading = true
    @State private var showingClearConfirmation = false

    private var filtered: [CacheEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.nl.lowercased().contains(query) || $0.en.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "No translations yet",
                        systemImage: "character.book.closed",
                        description: Text("Screens you translate build up here, and are then served instantly and offline.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(filtered, id: \.k) { entry in
                                Button {
                                    editing = entry
                                } label: {
                                    EntryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("\(entries.count) saved. Pinned entries always win over the model.")
                        }
                    }
                    .searchable(text: $search, prompt: "Search Dutch or English")
                }
            }
            .navigationTitle("Glossary")
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all saved translations?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task { await clear() }
                }
            } message: {
                Text("Your corrections will be lost and screens will need translating again.")
            }
            .sheet(item: $editing) { entry in
                GlossaryEditSheet(entry: entry) { corrected in
                    await pin(entry: entry, to: corrected)
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        let cache = await AppEnvironment.shared.cache()
        entries = await cache.allEntries()
        isLoading = false
    }

    private func pin(entry: CacheEntry, to corrected: String) async {
        let cache = await AppEnvironment.shared.cache()
        await cache.pin(nl: entry.nl, en: corrected)
        _ = try? await cache.flush()
        await reload()
    }

    private func clear() async {
        let cache = await AppEnvironment.shared.cache()
        try? await cache.removeAll()
        LastResultStore.clear()
        await reload()
    }
}

private struct EntryRow: View {
    let entry: CacheEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.nl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.en)
            }
            Spacer()
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned correction")
            }
        }
        .contentShape(Rectangle())
    }
}

private struct GlossaryEditSheet: View {
    let entry: CacheEntry
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Dutch") {
                    Text(entry.nl).foregroundStyle(.secondary)
                }
                Section("English") {
                    TextField("Translation", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return dismiss() }
                        Task {
                            await onSave(value)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { text = entry.en }
        }
    }
}
