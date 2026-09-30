import Foundation
import NLLensCore

/// Wires the core package to the device: where the cache lives, where the key
/// comes from, and which models are selected.
public final class AppEnvironment: @unchecked Sendable {

    public static let shared = AppEnvironment()

    /// Optional. When the App Group is configured the cache is shared with any
    /// future extension; without it everything still works, just app-local.
    public static let appGroupIdentifier = "group.com.nllens.shared"

    private let defaults: UserDefaults
    private let cacheActor: TranslationCache
    private var cacheLoaded = false
    private let memoryActor: MemoryStore
    private var memoryLoaded = false
    private let loadLock = NSLock()

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        self.cacheActor = TranslationCache(fileURL: Self.cacheFileURL())
        self.memoryActor = MemoryStore(fileURL: Self.memoryFileURL())
    }

    // MARK: - Storage locations

    static func containerURL() -> URL {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return group
        }
        // No App Group entitlement: fall back to Application Support so the
        // app still works on a plain personal build.
        let fallback = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return fallback
    }

    static func cacheFileURL() -> URL {
        containerURL()
            .appendingPathComponent("NLLens", isDirectory: true)
            .appendingPathComponent("translations.jsonl")
    }

    static func memoryFileURL() -> URL {
        containerURL()
            .appendingPathComponent("NLLens", isDirectory: true)
            .appendingPathComponent("memory.jsonl")
    }

    // MARK: - Settings

    private enum Key {
        static let settings = "nllens.settings"
        static let textModel = "nllens.textModel"
        static let visionModel = "nllens.visionModel"
        static let textBackups = "nllens.textBackups"
        static let visionBackups = "nllens.visionBackups"
    }

    public var settings: AppSettings {
        get {
            guard let data = defaults.data(forKey: Key.settings),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.settings)
        }
    }

    public var textModel: String {
        get { defaults.string(forKey: Key.textModel) ?? NebiusConfiguration.defaultTextModel }
        set { defaults.set(newValue, forKey: Key.textModel) }
    }

    public var visionModel: String {
        get { defaults.string(forKey: Key.visionModel) ?? NebiusConfiguration.defaultVisionModel }
        set { defaults.set(newValue, forKey: Key.visionModel) }
    }

    /// Models to try when the primary fails in a way another model could fix.
    ///
    /// Stored beside the primary rather than as one list, so an existing
    /// install keeps its chosen model and simply gains an empty backup list.
    public var textBackups: [String] {
        get { defaults.stringArray(forKey: Key.textBackups) ?? NebiusConfiguration.defaultTextBackups }
        set { defaults.set(newValue, forKey: Key.textBackups) }
    }

    public var visionBackups: [String] {
        get { defaults.stringArray(forKey: Key.visionBackups) ?? NebiusConfiguration.defaultVisionBackups }
        set { defaults.set(newValue, forKey: Key.visionBackups) }
    }

    public var textChain: ModelChain {
        ModelChain(primary: textModel, backups: textBackups)
    }

    public var visionChain: ModelChain {
        ModelChain(primary: visionModel, backups: visionBackups)
    }

    public var apiKey: String { Keychain.resolvedAPIKey() }
    public var hasAPIKey: Bool { !apiKey.isEmpty }

    public var searchKey: String { Keychain.resolvedSearchKey() }
    public var hasSearchKey: Bool { !searchKey.isEmpty }

    // MARK: - Assembly

    public var configuration: NebiusConfiguration {
        NebiusConfiguration(
            apiKey: apiKey,
            textModel: textModel,
            visionModel: visionModel
        )
    }

    public var client: NebiusClient {
        NebiusClient(configuration: configuration)
    }

    /// Nil without a key, which is what turns the lookup step off.
    public var searchClient: TavilyClient? {
        guard hasSearchKey else { return nil }
        return TavilyClient(apiKey: searchKey)
    }

    /// The shared cache, loaded from disk exactly once per process.
    public func cache() async -> TranslationCache {
        loadLock.lock()
        let needsLoad = !cacheLoaded
        cacheLoaded = true
        loadLock.unlock()

        if needsLoad {
            do {
                try await cacheActor.load()
            } catch {
                // A cache that fails to load is a degraded experience, never a
                // failed translation. Carry on with an empty one.
                NSLog("NLLens: cache load failed: \(error.localizedDescription)")
            }
        }
        return cacheActor
    }

    /// What the app remembers between screens, loaded once per process.
    public func memory() async -> MemoryStore {
        loadLock.lock()
        let needsLoad = !memoryLoaded
        memoryLoaded = true
        loadLock.unlock()

        if needsLoad {
            do {
                try await memoryActor.load()
            } catch {
                // Same posture as the cache: a memory that will not load is a
                // duller assistant, never a failed answer.
                NSLog("NLLens: memory load failed: \(error.localizedDescription)")
            }
        }
        return memoryActor
    }

    public func pipeline() async -> TranslationPipeline {
        TranslationPipeline(
            client: client,
            cache: settings.cacheEnabled ? await cache() : nil,
            settings: settings,
            textModel: textChain,
            search: searchClient,
            memory: settings.memoryEnabled ? await memory() : nil
        )
    }
}
