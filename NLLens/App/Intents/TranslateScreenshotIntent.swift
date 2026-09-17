import AppIntents
import SwiftUI
import UIKit
import NLLensCore

/// Translate whatever is on screen.
///
/// This is the name people pick, so it does the good thing: `openAppWhenRun`
/// brings NL Lens forward and draws the translated capture edge to edge.
///
/// It used to return a Shortcuts snippet instead, on the reasoning that never
/// leaving the Dutch app was worth more than size. In practice a snippet is a
/// system-sized card with a Done button on it — it cannot fill the display, no
/// matter how its contents are laid out — and a shortcut built against this
/// action silently got the worst of the three presentations. The card is not
/// worth the confusion, so the default now matches what the action's name
/// implies.
struct TranslateScreenshotIntent: AppIntent {

    static var title: LocalizedStringResource = "Translate Screen"
    static var description = IntentDescription(
        "Reads Dutch text from a screenshot and shows the translated screen at full size.",
        categoryName: "Translate"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Screenshot", supportedContentTypes: [.image])
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await FullScreenTranslationRun.perform(screenshot: screenshot)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }

    /// Spoken/banner line. Mentions redaction only when something was masked,
    /// so it stays quiet on ordinary screens.
    static func summary(for outcome: TranslationOutcome) -> String {
        var parts: [String] = ["Translated \(outcome.blocks.count) items"]
        if outcome.servedEntirelyFromCache {
            parts.append("from cache")
        } else if outcome.cacheHits > 0 {
            parts.append("\(outcome.cacheHits) from cache")
        }
        if outcome.redactedCount > 0 {
            parts.append("\(outcome.redactedCount) masked before sending")
        }
        return parts.joined(separator: ", ") + "."
    }
}

/// Explain the screen rather than translate it word for word.
///
/// This is the half a dictionary cannot do: on a Dutch form, knowing that a
/// field wants a BSN, or that a checkbox is pre-ticked, matters more than a
/// literal rendering of the label.
struct ExplainScreenIntent: AppIntent {

    static var title: LocalizedStringResource = "Explain Screen"
    static var description = IntentDescription(
        "Explains what a Dutch screen is asking you to do, and flags anything that costs money or grants consent.",
        categoryName: "Translate"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Screenshot", supportedContentTypes: [.image])
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let environment = AppEnvironment.shared

        guard environment.hasAPIKey else {
            return .result(
                dialog: "No Nebius API key set.",
                view: NLLensSnippetView.message(
                    "API key needed",
                    "Open NL Lens and paste your Nebius key in Settings.",
                    symbol: "key.slash"
                )
            )
        }
        guard let image = IntentImageLoader.image(from: screenshot),
              let jpeg = image.jpegData(compressionQuality: 0.6) else {
            return .result(
                dialog: "Could not read that screenshot.",
                view: NLLensSnippetView.message(
                    "Unreadable image",
                    "The shortcut did not pass a usable screenshot.",
                    symbol: "photo.badge.exclamationmark"
                )
            )
        }

        do {
            let pipeline = await environment.pipeline()
            let explanation = try await pipeline.explain(
                imageBase64: jpeg.base64EncodedString(),
                mimeType: "image/jpeg",
                visionModel: environment.visionModel
            )
            return .result(
                dialog: IntentDialog(stringLiteral: explanation.summary),
                view: NLLensSnippetView(content: .explanation(explanation))
            )
        } catch PipelineError.cloudDisabled {
            return .result(
                dialog: "Cloud is off.",
                view: NLLensSnippetView.message(
                    "Cloud is off",
                    "Explaining a screen needs the vision model. Turn cloud on in Settings.",
                    symbol: "icloud.slash"
                )
            )
        } catch let error as NebiusError {
            return .result(
                dialog: IntentDialog(stringLiteral: error.userMessage),
                view: NLLensSnippetView.message(
                    "Could not explain screen", error.userMessage,
                    symbol: "exclamationmark.triangle"
                )
            )
        } catch {
            return .result(
                dialog: "Could not explain that screen.",
                view: NLLensSnippetView.message(
                    "Could not explain screen", error.localizedDescription,
                    symbol: "exclamationmark.triangle"
                )
            )
        }
    }
}

/// English in, Dutch out, for filling in forms and replying to messages.
struct ComposeDutchIntent: AppIntent {

    static var title: LocalizedStringResource = "Write in Dutch"
    static var description = IntentDescription(
        "Turns English into natural Dutch at the register you choose, and copies it ready to paste.",
        categoryName: "Translate"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "English text")
    var english: String

    @Parameter(title: "Tone", default: RegisterAppEnum.formal)
    var register: RegisterAppEnum

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let environment = AppEnvironment.shared

        guard environment.hasAPIKey else {
            return .result(
                dialog: "No Nebius API key set.",
                view: NLLensSnippetView.message(
                    "API key needed",
                    "Open NL Lens and paste your Nebius key in Settings.",
                    symbol: "key.slash"
                )
            )
        }

        do {
            let pipeline = await environment.pipeline()
            let result = try await pipeline.compose(
                english: english, register: register.coreValue
            )
            // Straight to the clipboard: the next thing you do is paste it.
            UIPasteboard.general.string = result.dutch

            return .result(
                dialog: IntentDialog(stringLiteral: result.dutch),
                view: NLLensSnippetView(content: .compose(result))
            )
        } catch PipelineError.cloudDisabled {
            return .result(
                dialog: "Cloud is off.",
                view: NLLensSnippetView.message(
                    "Cloud is off",
                    "Writing Dutch needs the cloud model. Turn it on in Settings.",
                    symbol: "icloud.slash"
                )
            )
        } catch let error as NebiusError {
            return .result(
                dialog: IntentDialog(stringLiteral: error.userMessage),
                view: NLLensSnippetView.message(
                    "Could not translate", error.userMessage,
                    symbol: "exclamationmark.triangle"
                )
            )
        } catch {
            return .result(
                dialog: "Could not translate that.",
                view: NLLensSnippetView.message(
                    "Could not translate", error.localizedDescription,
                    symbol: "exclamationmark.triangle"
                )
            )
        }
    }
}

enum RegisterAppEnum: String, AppEnum {
    case formal, casual, business

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tone")
    static var caseDisplayRepresentations: [RegisterAppEnum: DisplayRepresentation] = [
        .formal: "Formal (u)",
        .casual: "Casual (je)",
        .business: "Business",
    ]

    var coreValue: Register {
        switch self {
        case .formal: return .formal
        case .casual: return .casual
        case .business: return .business
        }
    }
}

enum IntentImageLoader {
    /// Reads image bytes from an intent file, tolerating either the in-memory
    /// data or a file URL depending on how Shortcuts passed it.
    static func image(from file: IntentFile) -> UIImage? {
        if let data = try? file.data, let image = UIImage(data: data) {
            return image
        }
        if let url = file.fileURL,
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return nil
    }
}

/// Offers the intents to Shortcuts and Spotlight without any setup.
struct NLLensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranslateScreenshotIntent(),
            phrases: [
                "Translate screen with \(.applicationName)",
                "\(.applicationName) translate this",
            ],
            shortTitle: "Translate Screen",
            systemImageName: "textformat.abc.dottedunderline"
        )
        AppShortcut(
            intent: TranslateFullScreenIntent(),
            phrases: [
                "Translate screen full size with \(.applicationName)",
                "\(.applicationName) full screen translate",
            ],
            shortTitle: "Translate Full Size",
            systemImageName: "arrow.up.left.and.arrow.down.right"
        )
        AppShortcut(
            intent: TranslateLongScreenIntent(),
            phrases: [
                "Translate long screen with \(.applicationName)",
                "\(.applicationName) translate the whole page",
            ],
            shortTitle: "Translate Long Screen",
            systemImageName: "text.line.first.and.arrowtriangle.forward"
        )
        AppShortcut(
            intent: ExplainScreenIntent(),
            phrases: [
                "Explain screen with \(.applicationName)",
                "\(.applicationName) explain this screen",
            ],
            shortTitle: "Explain Screen",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: ComposeDutchIntent(),
            phrases: ["Write in Dutch with \(.applicationName)"],
            shortTitle: "Write in Dutch",
            systemImageName: "pencil.and.outline"
        )
    }
}
