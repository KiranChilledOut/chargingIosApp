import SwiftUI
import PhotosUI
import NLLensCore

/// The last translated screen at full size, with every pair correctable.
///
/// Correcting here is the point: a wrong translation of a label you see daily
/// is worth fixing once, and a pinned correction then outranks the model
/// forever and costs nothing to serve.
struct ReviewView: View {

    @State private var snapshot: LastResultStore.Snapshot?
    @State private var showingOriginal = false
    @State private var editing: TranslatedBlock?
    @State private var isLoading = true
    @State private var pickedItem: PhotosPickerItem?
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var offlineBlocks: [TextBlock] = []
    /// The picked image is held separately: on the offline path nothing has
    /// been stored yet, so `snapshot` still holds the *previous* screen.
    @State private var offlineImage: UIImage?
    /// Non-nil while the viewer is open, and which mode it opened in.
    @State private var openMode: OverlayViewerView.Mode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Above the fold in every state: the first run is the most
                    // likely moment for a bad key or model id, and burying the
                    // reason under the empty state makes it look like nothing
                    // happened at all.
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    if !offlineBlocks.isEmpty {
                        GroupBox("Cloud is off") {
                            OnDeviceTranslationView(blocks: offlineBlocks) { translated in
                                Task { await storeOfflineResult(translated) }
                            }
                        }
                    }

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if let snapshot {
                        content(for: snapshot)
                    } else {
                        EmptyStateView()
                    }
                }
                .padding()
            }
            .navigationTitle("Last Screen")
            .toolbar {
                if snapshot?.originalImage != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingOriginal.toggle()
                        } label: {
                            Image(systemName: showingOriginal
                                  ? "eye.fill" : "eye")
                        }
                        .accessibilityLabel(
                            showingOriginal ? "Show translation" : "Show original"
                        )
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickedItem, matching: .screenshots) {
                        if isTranslating {
                            ProgressView()
                        } else {
                            Image(systemName: "photo.badge.plus")
                        }
                    }
                    .disabled(isTranslating)
                    .accessibilityLabel("Translate a screenshot from Photos")
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await translatePicked(item) }
            }
            .fullScreenCover(item: $openMode) { mode in
                if let snapshot {
                    OverlayViewerView(
                        snapshot: snapshot,
                        initialMode: mode,
                        archivable: false
                    ) {
                        openMode = nil
                        Task { await reload() }
                    }
                }
            }
            .sheet(item: $editing) { block in
                CorrectionSheet(
                    sourceText: block.sourceText,
                    translatedText: block.translatedText
                ) { corrected in
                    await applyCorrection(for: block, to: corrected)
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    @ViewBuilder
    private func content(for snapshot: LastResultStore.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let image = showingOriginal
                ? snapshot.originalImage : snapshot.renderedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.quaternary)
                    )
            }

            Text(showingOriginal ? "Original" : "Translated")
                .font(.caption)
                .foregroundStyle(.secondary)

            let changed = snapshot.pairs.filter { $0.translatedText != $0.sourceText }
            if !changed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tap any line to correct it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)

                    ForEach(changed) { block in
                        Button {
                            editing = block
                        } label: {
                            PairRow(block: block)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private func reload() async {
        snapshot = LastResultStore.load()
        isLoading = false
    }

    /// In-app path, so the whole pipeline can be verified before Back Tap is
    /// wired up — and so a screenshot already in Photos can be translated.
    private func translatePicked(_ item: PhotosPickerItem) async {
        isTranslating = true
        errorMessage = nil
        offlineBlocks = []
        offlineImage = nil
        defer {
            isTranslating = false
            pickedItem = nil
        }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "That image could not be read."
            return
        }

        do {
            let result = try await ScreenTranslator.translate(image: image)
            // Open the viewer, exactly as Back Tap and the share sheet do.
            // Refreshing this tab in place left the picked image as the only
            // capture you could not read as text, explain, or ask about.
            OverlayPresenter.shared.present(
                LastResultStore.Snapshot(
                    renderedImage: result.rendered,
                    originalImage: result.original,
                    pairs: result.outcome.blocks,
                    createdAt: Date(),
                    redactedCount: result.outcome.redactedCount
                )
            )
            await reload()
        } catch PipelineError.cloudDisabled {
            // Cloud is off by choice, so offer the on-device route rather than
            // treating it as an error.
            offlineBlocks = (try? ScreenTranslator.recognize(image: image)) ?? []
            offlineImage = image
            if offlineBlocks.isEmpty {
                offlineImage = nil
                errorMessage = "Cloud is off and no text was recognised."
            }
        } catch let error as NebiusError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func storeOfflineResult(_ translated: [TranslatedBlock]) async {
        guard let original = offlineImage else {
            offlineBlocks = []
            return
        }
        let rendered = OverlayRenderer.render(image: original, blocks: translated)
        let outcome = TranslationOutcome(blocks: translated, servedEntirelyFromCache: true)
        LastResultStore.store(original: original, rendered: rendered, outcome: outcome)

        OverlayPresenter.shared.present(
            LastResultStore.Snapshot(
                renderedImage: rendered,
                originalImage: original,
                pairs: translated,
                createdAt: Date()
            )
        )
        offlineBlocks = []
        offlineImage = nil
        await reload()
    }

    private func applyCorrection(for block: TranslatedBlock, to corrected: String) async {
        await Corrections.pin(source: block.sourceText, to: corrected)

        // Reflect the fix immediately rather than waiting for the next run.
        if var current = snapshot {
            current.pairs = current.pairs.map {
                $0.id == block.id
                    ? TranslatedBlock(
                        id: $0.id, sourceText: $0.sourceText,
                        translatedText: corrected, box: $0.box, fromCache: true
                    )
                    : $0
            }
            snapshot = current
        }
    }
}

private struct PairRow: View {
    let block: TranslatedBlock

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(block.translatedText)
                    .font(.body)
            }
            Spacer()
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
                Label("No screen translated yet", systemImage: "text.viewfinder")
                    .font(.headline)

                Text("Set up the Back Tap shortcut once, then double-tap the back of your phone inside any Dutch app.")
                    .foregroundStyle(.secondary)

                GroupBox("One-time setup") {
                    VStack(alignment: .leading, spacing: 10) {
                        SetupStep(number: 1, text: "Open Shortcuts and create a shortcut.")
                        SetupStep(number: 2, text: "Add the action “Take Screenshot”.")
                        SetupStep(number: 3, text: "Add “Translate Screen” from NL Lens, and pass it the screenshot.")
                        SetupStep(number: 4, text: "In Settings › Accessibility › Touch › Back Tap, assign it to Double Tap.")
                    }
                    .padding(.top, 4)
                }

                Text("Assign “Explain Screen” to Triple Tap for forms, where knowing what a field wants matters more than a literal translation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

private struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
        }
        .font(.callout)
    }
}
