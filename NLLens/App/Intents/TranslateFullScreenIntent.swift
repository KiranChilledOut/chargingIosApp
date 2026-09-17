import AppIntents
import SwiftUI
import UIKit
import NLLensCore

/// Kept so that shortcuts built against this action keep working.
///
/// It behaves identically to `TranslateScreenshotIntent`, which is now the
/// default and does the same thing. Renaming or removing an action breaks any
/// shortcut already bound to it, and a shortcut that silently stops working is
/// worse than one extra entry in the Shortcuts picker.
struct TranslateFullScreenIntent: AppIntent {

    static var title: LocalizedStringResource = "Translate Screen (Full Size)"
    static var description = IntentDescription(
        "Reads Dutch text from a screenshot and shows the translated screen at full size.",
        categoryName: "Translate"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Screenshot", supportedContentTypes: [.image])
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult {
        await FullScreenTranslationRun.perform(screenshot: screenshot)
        return .result()
    }
}

/// The full-size translate flow, shared by the actions that present it.
///
/// Kept in one place because two actions run it: "Translate Screen", which is
/// the name anyone picks by default, and "Translate Screen (Full Size)", which
/// exists so shortcuts built before the default changed keep working.
enum FullScreenTranslationRun {

    /// Runs the flow. Deliberately silent: the app comes forward and shows
    /// the result, so a banner announcing what just happened is noise on top
    /// of the answer. Failures surface in the app too, through
    /// `OverlayPresenter.failure`, rather than as a notification.
    static func perform(screenshot: IntentFile) async {
        let environment = AppEnvironment.shared

        // Before any work: `openAppWhenRun` has already brought the app
        // forward, so without this it shows a blank tab for the two or three
        // seconds the translation takes — which reads as a Back Tap that
        // didn't register, and gets tapped again.
        OverlayPresenter.reportProgress(completed: 0, total: 1)

        guard environment.hasAPIKey || !environment.settings.cloudEnabled else {
            await fail("No Nebius API key set. Add one in Settings.")
            return
        }
        guard let image = IntentImageLoader.image(from: screenshot) else {
            await fail("Could not read that screenshot.")
            return
        }

        do {
            let result = try await ScreenTranslator.translate(image: image)
            OverlayPresenter.presentFromBackground(
                LastResultStore.Snapshot(
                    renderedImage: result.rendered,
                    originalImage: result.original,
                    pairs: result.outcome.blocks,
                    createdAt: Date(),
                    redactedCount: result.outcome.redactedCount
                )
            )

        } catch ScreenTranslator.Failure.noTextFound {
            await fail("No text found on that screen.")
        } catch PipelineError.cloudDisabled {
            await fail("Cloud translation is off. Turn it on in Settings.")
        } catch let error as NebiusError {
            await fail(error.userMessage)
        } catch {
            await fail("Translation failed.")
        }
    }

    /// Clears the progress indicator and shows the reason inside the app,
    /// since there is no longer a dialog to speak it through.
    @MainActor
    private static func fail(_ message: String) {
        OverlayPresenter.shared.progress = nil
        OverlayPresenter.shared.failure = message
    }
}
