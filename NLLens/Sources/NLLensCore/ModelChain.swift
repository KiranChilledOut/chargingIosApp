import Foundation

/// Models to try, in order.
///
/// Hosted open models fail in ways a different model fixes: one ignores the
/// response format, one is deployed text-only and rejects an image, one is
/// briefly rate limited, one is retired without warning. All of those are
/// survivable if there is somewhere else to go.
public struct ModelChain: Sendable, Equatable, Codable {
    public let models: [String]

    public init(_ models: [String]) {
        // Empty entries come from a picker set to "None"; duplicates would
        // make the same model fail twice before moving on.
        var seen = Set<String>()
        self.models = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public init(primary: String, backups: [String] = []) {
        self.init([primary] + backups)
    }

    public var primary: String { models.first ?? "" }
    public var backups: [String] { Array(models.dropFirst()) }
    public var isEmpty: Bool { models.isEmpty }
}

/// So a chain can be written where a model id used to be, and every existing
/// call site keeps working.
extension ModelChain: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init([value]) }
}

/// A model that did not work, and why.
public struct ModelFailure: Sendable, Equatable {
    public let model: String
    public let reason: String

    public init(model: String, reason: String) {
        self.model = model
        self.reason = reason
    }
}

/// What a chain produced, and what it cost to get there.
public struct Attempt<Value: Sendable>: Sendable {
    public let value: Value
    /// The model that actually answered.
    public let model: String
    /// The ones that failed first, in order.
    public let skipped: [ModelFailure]

    public var usedFallback: Bool { !skipped.isEmpty }

    public init(value: Value, model: String, skipped: [ModelFailure] = []) {
        self.value = value
        self.model = model
        self.skipped = skipped
    }
}

public enum ModelFallback {

    /// Whether a *different model* could plausibly succeed where this one
    /// failed.
    ///
    /// This is the whole design. Falling back on everything is worse than not
    /// falling back at all: a rejected API key fails identically on every
    /// model, so a three-model chain turns one immediate error into three
    /// round trips and the same message — and bills for two of them. The test
    /// is not "did it fail" but "is the failure about this model".
    public static func worthTryingAnother(_ error: Error) -> Bool {
        switch error {
        case let error as NebiusError:
            switch error {
            // The account, not the model. Every model gives the same answer.
            case .missingAPIKey, .unauthorized:
                return false
            // All of these are about this model: deployed without vision,
            // retired, out of capacity, context too long, broken reply.
            case .rateLimited, .serverError, .clientError, .invalidResponse,
                 .emptyCompletion, .truncated:
                return true
            }

        // The model ignored the response format and returned something the
        // schema decoder rejects. Another model honours it — this is exactly
        // the failure that made translation stop working.
        case is JSONExtraction.Error:
            return true

        // The network is down. Every model is equally unreachable, and trying
        // two more just makes the user wait three timeouts for one message.
        case is URLError:
            return false

        case is PipelineError, is WebSearchError:
            return false

        default:
            // Unknown, so unproven. A fallback costs a round trip and real
            // money; spending both on a guess is the wrong default.
            return false
        }
    }

    /// Runs `work` against each model until one succeeds.
    ///
    /// The last model's error is thrown if none work — not the first — because
    /// the last one is the one that ran with nothing left to try.
    public static func run<Value: Sendable>(
        chain: ModelChain,
        _ work: @Sendable (String) async throws -> Value
    ) async throws -> Attempt<Value> {
        guard !chain.isEmpty else { throw NebiusError.clientError(
            status: 400, message: "No model configured. Pick one in Settings."
        ) }

        var skipped: [ModelFailure] = []

        for (index, model) in chain.models.enumerated() {
            let isLast = index == chain.models.count - 1
            do {
                let value = try await work(model)
                return Attempt(value: value, model: model, skipped: skipped)
            } catch {
                guard !isLast, worthTryingAnother(error) else { throw error }
                skipped.append(ModelFailure(
                    model: model, reason: FailureText.describe(error)
                ))
            }
        }

        // Unreachable: the last iteration either returns or throws.
        throw NebiusError.invalidResponse
    }
}
