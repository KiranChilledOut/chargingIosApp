import SwiftUI
import NLLensCore

/// The translated screen at full size, edge to edge.
///
/// The rendered image has exactly the dimensions of the screen it came from,
/// so drawn full-bleed on black it reads as the original screen with English
/// on it, rather than as a picture of a screen. That is the closest this can
/// get to an overlay: iOS will not let an app draw over another app, but it
/// will let this app fill the display with a pixel-accurate copy.
struct OverlayViewerView: View {

    let snapshot: LastResultStore.Snapshot
    var onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var showingOriginal = false
    @State private var showingChrome = true

    private var image: UIImage? {
        showingOriginal ? snapshot.originalImage : snapshot.renderedImage
    }

    private var isZoomed: Bool { scale > 1.01 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
                    // Press and hold to check the Dutch underneath. Quicker
                    // than a button when you only want a half-second glance.
                    .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) {
                        // Long press completed; peeking is driven by `pressing`.
                    } onPressingChanged: { pressing in
                        showingOriginal = pressing
                    }
            } else {
                ContentUnavailableView(
                    "Nothing to show",
                    systemImage: "photo",
                    description: Text("The translated screen could not be loaded.")
                )
            }

            if showingChrome {
                chrome
            }
        }
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.15), value: showingOriginal)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")

                Spacer()

                if snapshot.originalImage != nil {
                    Button {
                        showingOriginal.toggle()
                    } label: {
                        Image(systemName: showingOriginal ? "eye.fill" : "eye")
                            .font(.headline)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(
                        showingOriginal ? "Show translation" : "Show original"
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            Text(showingOriginal ? "Original" : "Hold anywhere to see the Dutch")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
        .transition(.opacity)
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
                    // Not zoomed: follow the finger vertically as a dismiss hint.
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
