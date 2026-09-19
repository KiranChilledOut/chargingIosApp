import SwiftUI
import Combine
import NLLensCore

/// The models available on the account, cached so a picker can open instantly.
///
/// Fetched once and kept, because the catalogue changes on Nebius's schedule
/// rather than the user's, and a menu that stalls on a network call is a menu
/// nobody opens twice.
@MainActor
final class ModelCatalog: ObservableObject {

    static let shared = ModelCatalog()

    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let defaultsKey = "nllens.modelCatalog"
    private var hasLoaded = false

    private init() {
        models = cached()
    }

    var isEmpty: Bool { models.isEmpty }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        guard AppEnvironment.shared.hasAPIKey else {
            errorMessage = "Add a Nebius key in Settings first."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fetched = try await AppEnvironment.shared.client
                .listModels()
                .sorted { $0.id < $1.id }
            models = fetched
            hasLoaded = true
            store(fetched)
        } catch let error as NebiusError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The models worth offering for chat, most likely first.
    ///
    /// Embedding and vision-only entries are filtered out: picking one from a
    /// chat menu produces a confusing failure rather than an answer.
    var chatModels: [ModelInfo] {
        models.filter { model in
            let id = model.id.lowercased()
            return !id.contains("embed") && !id.contains("rerank")
                && !id.contains("whisper") && !id.contains("tts")
        }
    }

    // MARK: - Cache

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppEnvironment.appGroupIdentifier) ?? .standard
    }

    private func cached() -> [ModelInfo] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ModelInfo].self, from: data)
        else { return [] }
        return decoded
    }

    private func store(_ models: [ModelInfo]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
