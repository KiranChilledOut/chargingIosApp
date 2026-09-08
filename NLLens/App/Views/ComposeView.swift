import SwiftUI
import NLLensCore

/// English in, Dutch out, with the register chosen explicitly.
///
/// The register control is the reason this exists rather than a generic
/// translator: on a Dutch form the u/je choice is the mistake a non-speaker
/// makes, and no on-device translator will flag it.
struct ComposeView: View {

    @State private var english = ""
    @State private var register: Register = AppEnvironment.shared.settings.defaultRegister
    @State private var result: ComposeResult?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("English") {
                    TextField("What do you want to say?", text: $english, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($editorFocused)
                }

                Section("Tone") {
                    Picker("Tone", selection: $register) {
                        Text("Formal (u)").tag(Register.formal)
                        Text("Business").tag(Register.business)
                        Text("Casual (je)").tag(Register.casual)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        Task { await translate() }
                    } label: {
                        HStack {
                            Text("Translate to Dutch")
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || isWorking)
                }

                if let result {
                    Section("Dutch") {
                        Text(result.dutch)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = result.dutch
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

                    if !result.notes.isEmpty {
                        Section("Notes") {
                            ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                                Text(note)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Write in Dutch")
        }
    }

    private func translate() async {
        editorFocused = false
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let pipeline = await AppEnvironment.shared.pipeline()
            result = try await pipeline.compose(english: english, register: register)
        } catch let error as NebiusError {
            errorMessage = error.userMessage
        } catch PipelineError.cloudDisabled {
            errorMessage = "Cloud is off. Turn it on in Settings to write Dutch."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
