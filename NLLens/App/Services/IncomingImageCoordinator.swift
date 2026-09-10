import SwiftUI
import UIKit
import NLLensCore

/// Handles screenshots shared into the app from the system share sheet.
///
/// This is the path that needs no setup at all: screenshot, tap the thumbnail,
/// Share, NL Lens. No Shortcuts recipe, no trip into Accessibility settings,
/// working the moment the app is installed. Back Tap is faster once you have
/// it configured, but it is a poor first experience — this is what someone
/// should hit on day one.
///
/// Implemented by declaring the app as an image viewer rather than by shipping
/// a share extension, because an extension would need an App Group, and App
/// Groups need a paid developer account.
@MainActor
final class IncomingImageCoordinator: ObservableObject {

    static let shared = IncomingImageCoordinator()

    private var buffered: [UIImage] = []
    private var drainTask: Task<Void, Never>?

    /// Sharing several screenshots at once delivers them as separate calls in
    /// quick succession, so they are collected before processing — otherwise
    /// three shared screenshots would start three translations that each
    /// overwrite the last, instead of one stitched document.
    private let coalescingWindow: Duration = .milliseconds(400)

    private init() {}

    func handle(url: URL) {
        guard let image = Self.loadImage(at: url) else { return }
        Self.discardInboxCopy(at: url)

        buffered.append(image)
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            try? await Task.sleep(for: self?.coalescingWindow ?? .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func drain() async {
        let images = buffered
        buffered.removeAll()
        guard !images.isEmpty else { return }

        OverlayPresenter.shared.progress = .init(completed: 0, total: images.count)

        do {
            if images.count == 1 {
                let result = try await ScreenTranslator.translate(image: images[0])
                OverlayPresenter.shared.present(
                    LastResultStore.Snapshot(
                        renderedImage: result.rendered,
                        originalImage: result.original,
                        pairs: result.outcome.blocks,
                        createdAt: Date()
                    )
                )
            } else {
                let result = try await ScreenTranslator.translateMany(images: images) { done, total in
                    OverlayPresenter.reportProgress(completed: done, total: total)
                }
                OverlayPresenter.shared.present(
                    LastResultStore.Snapshot(
                        renderedImage: result.firstRendered,
                        originalImage: result.firstOriginal,
                        pairs: result.document.blocks,
                        createdAt: Date(),
                        screenCount: result.document.screenCount
                    )
                )
            }
        } catch {
            OverlayPresenter.shared.dismiss()
            OverlayPresenter.shared.failure = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? NebiusError { return error.userMessage }
        if case PipelineError.cloudDisabled = error {
            return "Cloud translation is off. Turn it on in Settings."
        }
        if let error = error as? ScreenTranslator.Failure {
            return error.errorDescription ?? "Translation failed."
        }
        return error.localizedDescription
    }

    // MARK: - Files

    private static func loadImage(at url: URL) -> UIImage? {
        // Shared files arrive copied into the app's Inbox, so no scope is
        // needed; opening in place does need one. Ask either way and only
        // release what was granted.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Inbox copies are ours to clean up; left alone they accumulate for the
    /// life of the install.
    private static func discardInboxCopy(at url: URL) {
        guard url.path.contains("/Inbox/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
