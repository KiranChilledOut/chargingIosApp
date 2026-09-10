import AppIntents
import SwiftUI
import UIKit
import NLLensCore

/// Translate the screen and show it at full size.
///
/// The sibling `TranslateScreenshotIntent` keeps you inside the Dutch app but
/// is confined to a Shortcuts snippet, which is a system-sized card and cannot
/// be made to fill the display. This one trades that: `openAppWhenRun` brings
/// NL Lens forward and hands the result to `OverlayViewerView`, which draws the
/// rendered screenshot edge to edge. Because that image has exactly the
/// dimensions of the screen it came from, it reads as the original screen with
/// English on it. Swipe down or press Close to go back to the Dutch app.
///
/// Bind whichever suits you to Back Tap; dense screens and long text want this
/// one, a single label wants the card.
struct TranslateFullScreenIntent: AppIntent {

    static var title: LocalizedStringResource = "Translate Screen Full Size"
    static var description = IntentDescription(
        "Reads Dutch text from a screenshot and shows the translated screen at full size.",
        categoryName: "Translate"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Screenshot", supportedContentTypes: [.image])
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = AppEnvironment.shared

        // Before any work: `openAppWhenRun` has already brought the app
        // forward, so without this it shows a blank tab for the two or three
        // seconds the translation takes — which reads as a Back Tap that
        // didn't register, and gets tapped again.
        OverlayPresenter.reportProgress(completed: 0, total: 1)

        guard environment.hasAPIKey || !environment.settings.cloudEnabled else {
            OverlayPresenter.clearProgress()
            return .result(dialog: "No Nebius API key set. Add one in Settings.")
        }
        guard let image = IntentImageLoader.image(from: screenshot) else {
            OverlayPresenter.clearProgress()
            return .result(dialog: "Could not read that screenshot.")
        }

        do {
            let result = try await ScreenTranslator.translate(image: image)
            OverlayPresenter.presentFromBackground(
                LastResultStore.Snapshot(
                    renderedImage: result.rendered,
                    originalImage: result.original,
                    pairs: result.outcome.blocks,
                    createdAt: Date()
                )
            )
            return .result(
                dialog: IntentDialog(
                    stringLiteral: TranslateScreenshotIntent.summary(for: result.outcome)
                )
            )
        } catch ScreenTranslator.Failure.noTextFound {
            OverlayPresenter.clearProgress()
            return .result(dialog: "No text found on that screen.")
        } catch PipelineError.cloudDisabled {
            OverlayPresenter.clearProgress()
            return .result(dialog: "Cloud translation is off. Turn it on in Settings.")
        } catch let error as NebiusError {
            OverlayPresenter.clearProgress()
            return .result(dialog: IntentDialog(stringLiteral: error.userMessage))
        } catch {
            OverlayPresenter.clearProgress()
            return .result(dialog: "Translation failed.")
        }
    }
}
