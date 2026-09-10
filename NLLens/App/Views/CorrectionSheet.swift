import SwiftUI
import NLLensCore

/// Fix a translation once, permanently.
///
/// Shared by the Screen tab and the full-size viewer so a correction is
/// always one tap away from wherever you noticed the mistake — the moment you
/// notice it is the only moment you reliably remember what it should say.
struct CorrectionSheet: View {

    let sourceText: String
    let translatedText: String
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Dutch") {
                    Text(sourceText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Section("English") {
                    TextField("Translation", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                }
                Section {
                    Text("Saved corrections always win over the model, and are served instantly and offline from then on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return dismiss() }
                        Task {
                            await onSave(value)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { text = translatedText }
        }
    }
}

/// Records a hand correction so it outranks the model from now on.
enum Corrections {
    static func pin(source: String, to corrected: String) async {
        let cache = await AppEnvironment.shared.cache()
        await cache.pin(nl: source, en: corrected)
        _ = try? await cache.flush()
    }
}
