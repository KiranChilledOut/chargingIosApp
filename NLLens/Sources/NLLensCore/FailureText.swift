import Foundation

/// Turns a thrown error into something worth showing someone.
///
/// The translate path used to end in `fail("Translation failed.")` for
/// anything that was not a `NebiusError`. That sentence contains no
/// information: it cannot be acted on, it does not say whether the problem is
/// the network, the key, the model or the screen, and it sent a real user
/// looking at their model settings for a fault that could have been anywhere.
///
/// The same mistake as the Tavily 401 that claimed to know why it failed. The
/// fix is the same too — say what actually happened, and name the next move
/// only when the error supports one.
public enum FailureText {

    public static func describe(_ error: Error) -> String {
        switch error {
        case let error as NebiusError:
            return error.userMessage
        case let error as WebSearchError:
            return error.userMessage
        case let error as PipelineError:
            return describe(error)
        case let error as JSONExtraction.Error:
            return describe(error)
        case let error as URLError:
            return describe(error)
        default:
            // Never just "failed". Whatever this is, its own description is
            // more use than a sentence that says nothing.
            return "Translation failed: \(error.localizedDescription)"
        }
    }

    static func describe(_ error: PipelineError) -> String {
        switch error {
        case .cloudDisabled:
            return "Cloud translation is off. Turn it on in Settings."
        case .nothingToTranslate:
            return "Nothing on that screen needed translating."
        }
    }

    /// A model that will not follow the schema is a model choice, and saying
    /// so is the difference between a setting someone can change and a bug
    /// they cannot.
    static func describe(_ error: JSONExtraction.Error) -> String {
        switch error {
        case .noJSONFound:
            return "The model replied with no usable JSON. Some models ignore the "
                + "response format — try a different text model in Settings."
        case .decodingFailed:
            return "The model replied in the wrong shape. Some models ignore the "
                + "response format — try a different text model in Settings."
        }
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No internet connection."
        case .timedOut:
            return "The request timed out. Try again."
        case .cannotFindHost, .cannotConnectToHost:
            return "Could not reach the server."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }
}
