import SwiftUI
import NLLensCore

struct SettingsView: View {

    @State private var apiKey = ""
    @State private var settings = AppEnvironment.shared.settings
    @State private var textModel = AppEnvironment.shared.textModel
    @State private var visionModel = AppEnvironment.shared.visionModel

    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var savedConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Nebius API key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save key") {
                        Keychain.setAPIKey(apiKey)
                        savedConfirmation = true
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Nebius Token Factory")
                } footer: {
                    Text("Stored in the keychain, never in the app's files. Get a key from your Nebius Token Factory account.")
                }

                Section {
                    Toggle("Use cloud translation", isOn: $settings.cloudEnabled)
                    Toggle("Mask postcodes too", isOn: $settings.redactionPolicyIsStrict)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("IBANs, BSNs, card numbers, emails and phone numbers are always masked before anything is sent, and restored in the result. Turning cloud off keeps everything on device.")
                }

                Section {
                    Toggle("Remember translations", isOn: $settings.cacheEnabled)
                    Toggle("Show Dutch alongside English", isOn: $settings.showSourceText)
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("Remembered translations are served instantly and offline, and cost nothing to repeat.")
                }

                Section {
                    Toggle("Check screens for scams", isOn: $settings.riskCheckEnabled)
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Looks for phishing signals — password requests, urgency, mismatched web addresses — and warns you only when something looks wrong. Costs one extra request per screen.")
                }

                Section {
                    if availableModels.isEmpty {
                        LabeledContent("Text model", value: textModel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        LabeledContent("Vision model", value: visionModel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Picker("Text model", selection: $textModel) {
                            ForEach(availableModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                        Picker("Vision model", selection: $visionModel) {
                            ForEach(availableModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                    }

                    Button {
                        Task { await loadModels() }
                    } label: {
                        HStack {
                            Text("Load models from Nebius")
                            Spacer()
                            if isLoadingModels { ProgressView() }
                        }
                    }
                    .disabled(isLoadingModels)

                    if let modelError {
                        Label(modelError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("The catalog changes over time. Load the list and pick a current model rather than trusting the defaults. The vision model must accept images.")
                }

                Section("Shortcut setup") {
                    NavigationLink("How to set up Back Tap") {
                        SetupGuideView()
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings) { _, newValue in
                AppEnvironment.shared.settings = newValue
            }
            .onChange(of: textModel) { _, newValue in
                AppEnvironment.shared.textModel = newValue
            }
            .onChange(of: visionModel) { _, newValue in
                AppEnvironment.shared.visionModel = newValue
            }
            .alert("Key saved", isPresented: $savedConfirmation) {
                Button("OK", role: .cancel) {}
            }
            .onAppear {
                // Show that a key exists without ever displaying it.
                if AppEnvironment.shared.hasAPIKey, apiKey.isEmpty {
                    apiKey = ""
                }
            }
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        modelError = nil
        defer { isLoadingModels = false }

        do {
            let client = AppEnvironment.shared.client
            let models = try await client.listModels().sorted { $0.id < $1.id }
            availableModels = models

            // Keep the current selection valid; a stale id would silently 404
            // on every request.
            if !models.contains(where: { $0.id == textModel }), let first = models.first {
                textModel = first.id
            }
            if !models.contains(where: { $0.id == visionModel }), let first = models.first {
                visionModel = first.id
            }
        } catch let error as NebiusError {
            modelError = error.userMessage
        } catch {
            modelError = error.localizedDescription
        }
    }
}

struct SetupGuideView: View {
    var body: some View {
        List {
            Section("Translate (double tap)") {
                Step(1, "Open Shortcuts and create a new shortcut.")
                Step(2, "Add the action “Take Screenshot”.")
                Step(3, "Add “Translate Screen” from NL Lens.")
                Step(4, "Make sure the screenshot is passed into it.")
                Step(5, "Name it, then go to Settings › Accessibility › Touch › Back Tap › Double Tap and choose it.")
            }
            Section("Explain (triple tap)") {
                Step(1, "Make a second shortcut the same way.")
                Step(2, "Use “Explain Screen” instead of “Translate Screen”.")
                Step(3, "Assign it to Back Tap › Triple Tap.")
            }
            Section {
                Text("Both run without opening NL Lens — the result appears on top of the app you are already in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Back Tap Setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
