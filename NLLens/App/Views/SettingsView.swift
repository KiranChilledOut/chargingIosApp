import SwiftUI
import NLLensCore

struct SettingsView: View {

    @State private var apiKey = ""
    @State private var searchKey = ""
    @State private var searchKeyWarning: String?
    @State private var keyCheck: TavilyKeyCheck?
    @State private var isCheckingKey = false
    /// Masked, and read from the keychain rather than the field — the field
    /// starts empty on every launch, so it cannot show what is actually saved.
    @State private var storedKeyPreview = TavilyClient.preview(of: Keychain.resolvedSearchKey())
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
                        Keychain.set(apiKey, for: .nebius)
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
                    SecureField("Tavily API key", text: $searchKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save search key") {
                        // Accepts the MCP URL as well as the bare key; the
                        // URL is what Tavily gives you, so it is what gets
                        // pasted.
                        let normalized = TavilyClient.normalizeKey(searchKey)
                        let stored = Keychain.set(normalized, for: .tavily)
                        searchKey = normalized
                        keyCheck = nil

                        // Read back rather than echoing what was sent: the
                        // preview is only useful if it shows what is actually
                        // in the keychain.
                        storedKeyPreview = TavilyClient.preview(of: Keychain.resolvedSearchKey())

                        if !stored {
                            searchKeyWarning = "The keychain refused to save that. Try again."
                        } else if !TavilyClient.looksLikeKey(normalized) {
                            searchKeyWarning = "That does not look like a Tavily key — they start with tvly-."
                        } else {
                            searchKeyWarning = nil
                        }
                        savedConfirmation = stored
                    }
                    .disabled(searchKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let searchKeyWarning {
                        Label(searchKeyWarning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    LabeledContent("Saved key", value: storedKeyPreview)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await checkSearchKey() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Test key")
                            if isCheckingKey {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isCheckingKey)

                    if let keyCheck {
                        KeyCheckRow(check: keyCheck)
                    }

                    Toggle("Look things up before answering", isOn: $settings.webSearchEnabled)
                } header: {
                    Text("Web search")
                } footer: {
                    Text("With a Tavily key, questions are checked against the current web before being answered — rates, thresholds and prices change every year, and a remembered figure is confidently wrong. One search per question. Paste either the key or the whole MCP URL — the key is pulled out of it. Get one at tavily.com, and use Test key to see whether it works.")
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

    /// Asks Tavily what this key actually does.
    ///
    /// A failed search can only ever say "not accepted" — Tavily answers a
    /// rotated key, a mistyped key and no key at all with the same 401 and the
    /// same body. Running one real request here is the only way to separate
    /// those from an exhausted plan, which is a 432 and not a key problem at
    /// all.
    private func checkSearchKey() async {
        isCheckingKey = true
        keyCheck = nil
        defer { isCheckingKey = false }

        // Deliberately from the keychain, not the text field: the field is
        // empty on a fresh launch, and testing what is typed rather than what
        // is saved would pass while the app keeps failing.
        let stored = Keychain.resolvedSearchKey()
        storedKeyPreview = TavilyClient.preview(of: stored)
        keyCheck = await TavilyClient(apiKey: stored).check()
    }
}

/// The outcome of a key test, said plainly enough to act on.
private struct KeyCheckRow: View {
    let check: TavilyKeyCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(check.headline, systemImage: check.isWorking ? "checkmark.circle" : "xmark.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(check.isWorking ? Color.green : Color.orange)

            if let advice = check.advice {
                Text(advice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Tavily's own words. Paraphrasing a server error is how a
            // diagnosis turns into a guess.
            if !check.serverMessage.isEmpty {
                Text("Tavily said: \(check.serverMessage)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
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
