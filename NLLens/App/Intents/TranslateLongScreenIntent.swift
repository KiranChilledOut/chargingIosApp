import AppIntents
import SwiftUI
import UIKit
import NLLensCore

/// Translate something longer than one screen.
///
/// A screenshot captures a screen, not a document, so anything longer has to
/// be taken in pieces — and the single-capture flow makes you scroll, fire the
/// shortcut, read, scroll, fire again, losing your place each time. This takes
/// all the captures at once and returns one continuous English document.
///
/// Consecutive captures overlap, because people deliberately scroll less than
/// a full screen so as not to miss a line. `ScreenStitching` finds that
/// overlap and drops the repeat, and the translation cache means the repeated
/// lines cost nothing to translate a second time.
///
/// Shortcuts recipe: **Get Latest Screenshots** (count: however many you took)
/// → **Reverse** so they run oldest first → this action.
struct TranslateLongScreenIntent: AppIntent {

    static var title: LocalizedStringResource = "Translate Long Screen"
    static var description = IntentDescription(
        "Joins several screenshots taken while scrolling into one continuous English document.",
        categoryName: "Translate"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Screenshots", supportedContentTypes: [.image])
    var screenshots: [IntentFile]

    func perform() async throws -> some IntentResult {
        let environment = AppEnvironment.shared

        // Raised before the images are even decoded, so the app never shows a
        // blank tab after being brought forward.
        OverlayPresenter.reportProgress(completed: 0, total: max(screenshots.count, 1))

        guard environment.hasAPIKey || !environment.settings.cloudEnabled else {
            await fail("No Nebius API key set. Add one in Settings.")
            return .result()
        }

        let images = screenshots.compactMap(IntentImageLoader.image(from:))
        guard !images.isEmpty else {
            await fail("Could not read those screenshots.")
            return .result()
        }

        OverlayPresenter.reportProgress(completed: 0, total: images.count)

        do {
            let result = try await ScreenTranslator.translateMany(images: images) { done, total in
                OverlayPresenter.reportProgress(completed: done, total: total)
            }

            OverlayPresenter.presentFromBackground(
                LastResultStore.Snapshot(
                    renderedImage: result.firstRendered,
                    originalImage: result.firstOriginal,
                    pairs: result.document.blocks,
                    createdAt: Date(),
                    screenCount: result.document.screenCount,
                    redactedCount: result.outcome.redactedCount
                )
            )

            return .result()
        } catch ScreenTranslator.Failure.noTextFound {
            await fail("No text found in those screenshots.")
            return .result()
        } catch PipelineError.cloudDisabled {
            await fail("Cloud translation is off. Turn it on in Settings.")
            return .result()
        } catch let error as NebiusError {
            await fail(error.userMessage)
            return .result()
        } catch {
            await fail("Translation failed.")
            return .result()
        }
    }

    @MainActor
    private func fail(_ message: String) {
        OverlayPresenter.shared.progress = nil
        OverlayPresenter.shared.failure = message
    }
}
