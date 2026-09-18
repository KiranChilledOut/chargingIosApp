import SwiftUI
import NLLensCore

/// Every screen you have translated, searchable in English.
struct HistoryView: View {

    @State private var entries: [ArchiveEntry] = []
    @State private var query = ""
    @State private var opened: ArchiveEntry?
    @State private var confirmingClear = false

    private var results: [ArchiveEntry] {
        ArchiveStore.search(query, in: entries)
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Screens you translate are kept here, searchable in English.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { confirmingClear = true }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search in English or Dutch")
            .confirmationDialog(
                "Delete everything saved?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    ArchiveStore.deleteAll()
                    reload()
                }
            } message: {
                Text("Every saved screen and conversation will be lost.")
            }
            .fullScreenCover(item: $opened) { entry in
                ArchivedScreenView(entry: entry) { opened = nil }
            }
            .task { reload() }
            .refreshable { reload() }
        }
    }

    private var list: some View {
        List {
            ForEach(results) { entry in
                Button {
                    opened = entry
                } label: {
                    HistoryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        ArchiveStore.delete(entry)
                        reload()
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func reload() {
        entries = ArchiveStore.all()
    }
}

private struct HistoryRow: View {
    let entry: ArchiveEntry

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            thumbnail

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(entry.title)
                    .font(Theme.Typeface.reading)
                    .lineLimit(2)

                HStack(spacing: Theme.Space.s) {
                    Text(entry.createdAt, format: .dateTime.day().month().hour().minute())
                    if entry.questionCount > 0 {
                        Label("\(entry.questionCount)", systemImage: "bubble.left")
                    }
                }
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = ArchiveStore.image(for: entry) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(Theme.Palette.surface)
                .frame(width: 44, height: 58)
                .overlay(
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                )
        }
    }
}

/// Reopens an archived screen with everything the viewer can do — the image,
/// the text, an explanation, and the conversation as it was left.
private struct ArchivedScreenView: View {
    let entry: ArchiveEntry
    var onDismiss: () -> Void

    var body: some View {
        OverlayViewerView(
            snapshot: LastResultStore.Snapshot(
                renderedImage: ArchiveStore.image(for: entry),
                originalImage: nil,
                pairs: pairs,
                createdAt: entry.createdAt
            ),
            archivable: false,
            onDismiss: onDismiss
        )
    }

    /// The archive keeps text, not geometry, so the blocks are reconstructed
    /// flat. Reading, explaining and asking all work; drawing an overlay does
    /// not, which is why no original image is offered.
    private var pairs: [TranslatedBlock] {
        let english = entry.englishText.components(separatedBy: "\n")
        let dutch = entry.dutchText.components(separatedBy: "\n")

        return english.enumerated().map { index, line in
            TranslatedBlock(
                id: index,
                sourceText: index < dutch.count ? dutch[index] : line,
                translatedText: line,
                box: BoundingBox(
                    x: 0, y: Double(index) * 0.04, width: 1, height: 0.03
                ),
                fromCache: true
            )
        }
    }
}
