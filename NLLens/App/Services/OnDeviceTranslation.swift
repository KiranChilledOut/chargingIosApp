import SwiftUI
import Translation
import NLLensCore

/// Apple's on-device Dutch→English translation, used when the cloud is off.
///
/// It is worse than the model path — no OCR repair, no context, no register —
/// but it is free, offline, and nothing leaves the phone, which is the right
/// trade for a banking or health screen. Apple's API is SwiftUI-only, so this
/// is a view rather than a service, and it cannot run inside the background
/// App Intent: cloud-off translation happens here, in the app.
@available(iOS 18.0, *)
struct OnDeviceTranslationView: View {

    let blocks: [TextBlock]
    let onFinished: ([TranslatedBlock]) -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case working
        case failed(String)
        case done(Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                start()
            } label: {
                HStack {
                    Label("Translate on device", systemImage: "iphone")
                    Spacer()
                    if status == .working { ProgressView() }
                }
            }
            .disabled(status == .working || blocks.isEmpty)

            switch status {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .done(let count):
                Label("Translated \(count) items on device", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle:
                Text("Nothing leaves your phone. Quality is lower than the cloud model, and OCR errors are not repaired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .working:
                EmptyView()
            }
        }
        .translationTask(configuration) { session in
            await run(session: session)
        }
    }

    private func start() {
        status = .working
        let language = TranslationSession.Configuration(
            source: Locale.Language(identifier: "nl"),
            target: Locale.Language(identifier: "en")
        )
        // Re-assigning the configuration is what re-triggers `translationTask`.
        configuration = nil
        configuration = language
    }

    private func run(session: TranslationSession) async {
        do {
            let requests = blocks.map {
                TranslationSession.Request(
                    sourceText: $0.text, clientIdentifier: String($0.id)
                )
            }
            let boxesByID = Dictionary(
                blocks.map { ($0.id, $0.box) }, uniquingKeysWith: { first, _ in first }
            )
            let sourceByID = Dictionary(
                blocks.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first }
            )

            var translated: [TranslatedBlock] = []
            for try await response in session.translate(batch: requests) {
                guard let identifier = response.clientIdentifier,
                      let id = Int(identifier),
                      let box = boxesByID[id] else { continue }

                translated.append(TranslatedBlock(
                    id: id,
                    sourceText: sourceByID[id] ?? response.sourceText,
                    translatedText: response.targetText,
                    box: box
                ))
            }

            translated.sort { $0.id < $1.id }
            status = .done(translated.count)
            onFinished(translated)
        } catch {
            // The most common cause is the nl→en pack not being downloaded.
            status = .failed(
                "On-device translation unavailable. Download Dutch in Settings › Apps › Translate › Downloaded Languages."
            )
        }
    }
}
