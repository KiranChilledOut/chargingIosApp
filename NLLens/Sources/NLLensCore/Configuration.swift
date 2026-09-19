import Foundation

/// Everything the pipeline needs to talk to Nebius Token Factory.
public struct NebiusConfiguration: Sendable, Equatable, Codable {
    public var baseURL: URL
    public var apiKey: String

    /// Text model used for the translate path. Cheap and fast is right here:
    /// the job is repairing OCR noise and translating short UI strings.
    public var textModel: String

    /// Vision model used for the "explain this screen" path, where icons and
    /// layout carry meaning that extracted text alone loses.
    public var visionModel: String

    public var requestTimeout: TimeInterval
    public var maxRetries: Int

    /// Defaults point at models observed on Token Factory, but the catalog
    /// changes. The app fetches `/v1/models` at runtime and lets you pick,
    /// so a wrong default here is a one-tap fix rather than a rebuild.
    public static let defaultTextModel = "Qwen/Qwen3-235B-A22B-Instruct-2507"
    public static let defaultVisionModel = "google/gemma-3-27b-it"
    public static let defaultBaseURL = URL(string: "https://api.tokenfactory.nebius.com/v1")!

    public init(
        baseURL: URL = NebiusConfiguration.defaultBaseURL,
        apiKey: String,
        textModel: String = NebiusConfiguration.defaultTextModel,
        visionModel: String = NebiusConfiguration.defaultVisionModel,
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 2
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.textModel = textModel
        self.visionModel = visionModel
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
    }

    public var isUsable: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// User-facing behaviour switches, persisted in the App Group.
public struct AppSettings: Sendable, Equatable, Codable {
    /// When false, nothing ever leaves the device — the app falls back to
    /// Apple's on-device translation. This is the kill switch for banking apps.
    public var cloudEnabled: Bool
    public var redactionPolicyIsStrict: Bool
    public var cacheEnabled: Bool
    /// Show repaired Dutch beside the English, for learning.
    public var showSourceText: Bool
    /// Look things up on the web before answering a question.
    ///
    /// On when a Tavily key is present. Costs one search per question, and
    /// buys answers that rest on current figures rather than on whatever the
    /// model remembers — which for rates, thresholds and prices is usually
    /// both confident and out of date.
    public var webSearchEnabled: Bool
    /// Whether to carry facts between screens. On by default: a translator
    /// that forgets what you told it last week is the thing people complain
    /// about, not a feature they opt into.
    public var memoryEnabled: Bool
    /// Check captured screens for phishing signals automatically.
    ///
    /// On by default and automatic on purpose: a scam check you have to
    /// remember to ask for is one you will not run on the screen that needed
    /// it. It costs one extra vision call per capture.
    public var riskCheckEnabled: Bool
    public var defaultRegister: Register

    public init(
        cloudEnabled: Bool = true,
        redactionPolicyIsStrict: Bool = false,
        cacheEnabled: Bool = true,
        showSourceText: Bool = false,
        riskCheckEnabled: Bool = true,
        webSearchEnabled: Bool = true,
        memoryEnabled: Bool = true,
        defaultRegister: Register = .formal
    ) {
        self.cloudEnabled = cloudEnabled
        self.redactionPolicyIsStrict = redactionPolicyIsStrict
        self.cacheEnabled = cacheEnabled
        self.showSourceText = showSourceText
        self.riskCheckEnabled = riskCheckEnabled
        self.webSearchEnabled = webSearchEnabled
        self.memoryEnabled = memoryEnabled
        self.defaultRegister = defaultRegister
    }

    public var redactionPolicy: Redactor.Policy {
        redactionPolicyIsStrict ? .strict : .standard
    }

    public static let `default` = AppSettings()
}
