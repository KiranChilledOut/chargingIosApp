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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = AppEnvironment.shared

        guard environment.hasAPIKey || !environment.settings.cloudEnabled else {
            return .result(dialog: "No Nebius API key set. Add one in Settings.")
        }

        let images = screenshots.compactMap(IntentImageLoader.image(from:))
        guard !images.isEmpty else {
            OverlayPresenter.clearProgress()
            return .result(dialog: "Could not read those screenshots.")
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
                    screenCount: result.document.screenCount
                )
            )

            return .result(dialog: IntentDialog(stringLiteral: Self.summary(for: result)))
        } catch ScreenTranslator.Failure.noTextFound {
            OverlayPresenter.clearProgress()
            return .result(dialog: "No text found in those screenshots.")
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

    static func summary(for result: ScreenTranslator.MultiResult) -> String {
        var parts = [
            "Joined \(result.document.screenCount) screens into \(result.document.blocks.count) lines"
        ]
        if result.document.duplicatesRemoved > 0 {
            parts.append("\(result.document.duplicatesRemoved) repeated lines merged")
        }
        if result.outcome.redactedCount > 0 {
            parts.append("\(result.outcome.redactedCount) masked before sending")
        }
        return parts.joined(separator: ", ") + "."
    }
}
