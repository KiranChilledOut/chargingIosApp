import SwiftUI
import UIKit
import NLLensCore

/// The translated screen, either drawn over the original layout or reflowed
/// as text.
///
/// Two modes because the right answer depends on what was on screen. A screen
/// of controls needs the overlay: knowing which label belongs to which button
/// is the whole point, and text alone throws that away. A screen of prose
/// needs reading mode: an image of text does not reflow, does not honour
/// Dynamic Type, cannot be selected, and stops at the bottom of the capture.
///
/// Stitched multi-capture documents open in reading mode, because their boxes
/// come from different captures and no longer share a coordinate space.
struct OverlayViewerView: View {

    enum Mode: Hashable {
        case image, reading, explain

        var symbol: String {
            switch self {
            case .image: return "photo"
            case .reading: return "text.alignleft"
            case .explain: return "questionmark.bubble"
            }
        }

        var label: String {
            switch self {
            case .image: return "Show the screen"
            case .reading: return "Read as text"
            case .explain: return "Explain this screen"
            }
        }
    }

    let snapshot: LastResultStore.Snapshot
    var onDismiss: () -> Void

    @State private var mode: Mode
    /// Local copy so a correction shows immediately, without a round trip.
    @State private var blocks: [TranslatedBlock]
    @State private var editing: TranslatedBlock?
    @State private var showingOriginal = false
    @State private var showingChrome = true
    @State private var didCopy = false
    @State private var explanation: ScreenExplanation?
    @State private var isExplaining = false
    @State private var explainError: String?

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let settings = AppEnvironment.shared.settings

    init(snapshot: LastResultStore.Snapshot, onDismiss: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onDismiss = onDismiss
        _mode = State(initialValue: snapshot.isMultiScreen ? .reading : .image)
        _blocks = State(initialValue: snapshot.pairs)
    }

    private var image: UIImage? {
        showingOriginal ? snapshot.originalImage : snapshot.renderedImage
    }

    private var isZoomed: Bool { scale > 1.01 }
    private var canShowImage: Bool { snapshot.renderedImage != nil }

    var body: some View {
        ZStack {
            (mode == .image ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            switch mode {
            case .image:
                imageLayer
                if showingChrome { chrome.transition(.opacity) }
            case .reading:
                VStack(spacing: 0) {
                    chromeBar
                    ReadingModeView(
                        blocks: blocks,
                        showSource: settings.showSourceText
                    ) { block in
                        editing = block
                    }
                }
            case .explain:
                VStack(spacing: 0) {
                    chromeBar
                    ExplanationView(
                        explanation: explanation ?? ScreenExplanation(summary: ""),
                        isLoading: isExplaining,
                        errorMessage: explainError,
                        onRetry: { Task { await explainScreen(force: true) } }
                    )
                }
            }
        }
        .statusBarHidden(mode == .image)
        .task(id: mode) {
            // Requested lazily: it costs a vision call, so it should only
            // happen when the tab is actually opened.
            if mode == .explain { await explainScreen() }
        }
        .animation(.easeInOut(duration: 0.15), value: showingOriginal)
        .animation(.easeInOut(duration: 0.2), value: mode)
        .sheet(item: $editing) { block in
            CorrectionSheet(
                sourceText: block.sourceText,
                translatedText: block.translatedText
            ) { corrected in
                await applyCorrection(block, to: corrected)
            }
        }
        .onAppear {
            // The result has already arrived by the time this is on screen, so
            // the confirmation is for a translation that is done, not starting.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: - Image mode

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .ignoresSafeArea()
                .gesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
                .onTapGesture(count: 2) { toggleZoom() }
                .onTapGesture { withAnimation { showingChrome.toggle() } }
                .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) {
                    // Completion is unused; peeking is driven by `pressing`.
                } onPressingChanged: { pressing in
                    showingOriginal = pressing
                }
        } else {
            ContentUnavailableView(
                "No image",
                systemImage: "photo",
                description: Text("Switch to text to read this translation.")
            )
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            chromeBar
            Spacer()
            Text(showingOriginal ? "Original" : "Hold anywhere to see the Dutch")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private var chromeBar: some View {
        HStack(spacing: 12) {
            circleButton("xmark", label: "Close", action: onDismiss)

            Spacer()

            if didCopy {
                Text("Copied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            if mode == .reading {
                circleButton("doc.on.doc", label: "Copy all", action: copyAll)
            } else if mode == .image, snapshot.originalImage != nil {
                circleButton(
                    showingOriginal ? "eye.fill" : "eye",
                    label: showingOriginal ? "Show translation" : "Show original"
                ) {
                    showingOriginal.toggle()
                }
            }

            modePicker
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Three explicit modes rather than a cycling toggle: with more than two
    /// destinations a toggle stops being guessable.
    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(availableModes, id: \.self) { candidate in
                Button {
                    mode = candidate
                } label: {
                    Image(systemName: candidate.symbol)
                        .font(.subheadline)
                        .frame(width: 32, height: 30)
                        .background {
                            if mode == candidate {
                                Capsule().fill(.tint.opacity(0.25))
                            }
                        }
                }
                .accessibilityLabel(candidate.label)
                .accessibilityAddTraits(mode == candidate ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var availableModes: [Mode] {
        var modes: [Mode] = []
        if canShowImage { modes.append(.image) }
        modes.append(.reading)
        // Explaining needs the untranslated screen to send to a vision model.
        if snapshot.originalImage != nil { modes.append(.explain) }
        return modes
    }

    private func circleButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 20, height: 20)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private func copyAll() {
        UIPasteboard.general.string = TypographyHints.plainText(
            for: blocks, includingSource: settings.showSourceText
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { didCopy = true }

        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { didCopy = false }
        }
    }

    /// Asks a vision model what the screen is for. Cached for the life of the
    /// viewer so switching tabs does not re-spend the call.
    private func explainScreen(force: Bool = false) async {
        guard force || (explanation == nil && !isExplaining) else { return }
        guard let original = snapshot.originalImage,
              let jpeg = original.jpegData(compressionQuality: 0.6) else {
            explainError = "This screen could not be sent for explaining."
            return
        }

        isExplaining = true
        explainError = nil
        defer { isExplaining = false }

        do {
            let environment = AppEnvironment.shared
            let pipeline = await environment.pipeline()
            explanation = try await pipeline.explain(
                imageBase64: jpeg.base64EncodedString(),
                mimeType: "image/jpeg",
                visionModel: environment.visionModel
            )
        } catch PipelineError.cloudDisabled {
            explainError = "Cloud is off. Explaining a screen needs the vision model."
        } catch let error as NebiusError {
            explainError = error.userMessage
        } catch {
            explainError = error.localizedDescription
        }
    }

    private func applyCorrection(_ block: TranslatedBlock, to corrected: String) async {
        await Corrections.pin(source: block.sourceText, to: corrected)
        blocks = blocks.map {
            $0.id == block.id
                ? TranslatedBlock(
                    id: $0.id, sourceText: $0.sourceText,
                    translatedText: corrected, box: $0.box, fromCache: true
                )
                : $0
        }
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1.01 { resetPan() }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if isZoomed {
                    offset = CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    )
                } else {
                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                if isZoomed {
                    committedOffset = offset
                } else if value.translation.height > 120 {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.3)) { resetPan() }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isZoomed {
                scale = 1
                committedScale = 1
                resetPan()
            } else {
                scale = 2.5
                committedScale = 2.5
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}
