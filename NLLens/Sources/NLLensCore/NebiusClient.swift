import Foundation

public enum NebiusError: Swift.Error, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case serverError(status: Int, message: String)
    case clientError(status: Int, message: String)
    case invalidResponse
    case emptyCompletion

    /// Whether another attempt could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError:
            return true
        case .missingAPIKey, .unauthorized, .clientError, .invalidResponse, .emptyCompletion:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "No Nebius API key set. Add one in Settings."
        case .unauthorized:
            return "Nebius rejected the API key. Check it in Settings."
        case .rateLimited:
            return "Rate limited by Nebius. Try again in a moment."
        case .serverError(let status, _):
            return "Nebius server error (\(status)). Try again shortly."
        case .clientError(_, let message):
            return message.isEmpty ? "Request rejected by Nebius." : message
        case .invalidResponse:
            return "Unexpected response from Nebius."
        case .emptyCompletion:
            return "The model returned nothing. Try again."
        }
    }
}

public enum ChatRole: String, Sendable, Codable {
    case system, user, assistant
}

public enum ChatContent: Sendable, Equatable {
    case text(String)
    /// Base64-encoded image, sent as a data URL.
    case imageBase64(String, mimeType: String)
}

public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var content: [ChatContent]

    public init(role: ChatRole, content: [ChatContent]) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: [.text(text)])
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: [.text(text)])
    }

    public var hasImage: Bool {
        content.contains {
            if case .imageBase64 = $0 { return true }
            return false
        }
    }
}

public struct ModelInfo: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// Minimal OpenAI-compatible client for Nebius Token Factory.
public struct NebiusClient: Sendable {
    private let configuration: NebiusConfiguration
    private let transport: any HTTPTransport
    /// Injected so tests do not actually sleep through the backoff.
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        configuration: NebiusConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sleeper = sleeper ?? { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    // MARK: - Chat

    /// Sends a chat completion and returns the assistant's text content.
    public func complete(
        messages: [ChatMessage],
        model: String,
        temperature: Double = 0.2,
        maxTokens: Int = 2048
    ) async throws -> String {
        guard configuration.isUsable else { throw NebiusError.missingAPIKey }

        let body = try encodeRequestBody(
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens
        )
        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("chat/completions"),
            method: "POST",
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Content-Type": "application/json",
            ],
            body: body,
            timeout: configuration.requestTimeout
        )

        let response = try await sendWithRetry(request)
        return try extractContent(from: response.body)
    }

    /// Lists available models, so the app can offer a picker instead of
    /// hard-coding a model id that may have been retired.
    public func listModels() async throws -> [ModelInfo] {
        guard configuration.isUsable else { throw NebiusError.missingAPIKey }

        let request = HTTPRequest(
            url: configuration.baseURL.appendingPathComponent("models"),
            method: "GET",
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: nil,
            timeout: configuration.requestTimeout
        )
        let response = try await sendWithRetry(request)

        guard
            let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let data = root["data"] as? [[String: Any]]
        else {
            throw NebiusError.invalidResponse
        }
        return data.compactMap { ($0["id"] as? String).map(ModelInfo.init(id:)) }
    }

    // MARK: - Transport

    private func sendWithRetry(_ request: HTTPRequest) async throws -> HTTPResponse {
        var lastError: Swift.Error = NebiusError.invalidResponse

        for attempt in 0...max(0, configuration.maxRetries) {
            if attempt > 0 {
                // 0.5s, 1s, 2s … enough to clear a brief 429 without making
                // the user think the app has hung.
                try await sleeper(0.5 * pow(2, Double(attempt - 1)))
            }

            do {
                let response = try await transport.send(request)
                if (200..<300).contains(response.statusCode) {
                    return response
                }
                let error = Self.mapStatus(response.statusCode, body: response.body)
                if !error.isRetryable { throw error }
                lastError = error
            } catch let error as NebiusError {
                if !error.isRetryable { throw error }
                lastError = error
            } catch {
                // Transport-level failure: worth another attempt.
                lastError = error
            }
        }
        throw lastError
    }

    static func mapStatus(_ status: Int, body: Data) -> NebiusError {
        let message = Self.errorMessage(from: body)
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 400..<500: return .clientError(status: status, message: message)
        default: return .serverError(status: status, message: message)
        }
    }

    /// Pulls `error.message` out of an OpenAI-style error envelope.
    static func errorMessage(from body: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return "" }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = root["message"] as? String { return message }
        return ""
    }

    // MARK: - Codec

    // Wire types for the OpenAI-compatible request body. Modelled with
    // `Codable` rather than `JSONSerialization` because the latter escapes
    // forward slashes with no way to opt out, and a base64 screenshot is full
    // of them.
    private struct WireImageURL: Encodable {
        let url: String
    }

    private struct WirePart: Encodable {
        let type: String
        var text: String?
        var imageURL: WireImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    private enum WireContent: Encodable {
        case string(String)
        case parts([WirePart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .parts(let value): try container.encode(value)
            }
        }
    }

    private struct WireMessage: Encodable {
        let role: String
        let content: WireContent
    }

    private struct WireRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    func encodeRequestBody(
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        maxTokens: Int
    ) throws -> Data {
        let wireMessages: [WireMessage] = messages.map { message in
            // Text-only messages use the plain string form. Some hosted models
            // reject the array form when there is no image, so only multimodal
            // messages get the parts array.
            guard message.hasImage else {
                let text = message.content.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                return WireMessage(role: message.role.rawValue, content: .string(text))
            }

            let parts = message.content.map { part -> WirePart in
                switch part {
                case .text(let value):
                    return WirePart(type: "text", text: value, imageURL: nil)
                case .imageBase64(let base64, let mimeType):
                    return WirePart(
                        type: "image_url",
                        text: nil,
                        imageURL: WireImageURL(url: "data:\(mimeType);base64,\(base64)")
                    )
                }
            }
            return WireMessage(role: message.role.rawValue, content: .parts(parts))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(WireRequest(
            model: model,
            messages: wireMessages,
            temperature: temperature,
            maxTokens: maxTokens
        ))
    }

    func extractContent(from body: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw NebiusError.invalidResponse
        }

        // Content is usually a string, but reasoning-style models sometimes
        // return an array of parts.
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw NebiusError.emptyCompletion }
            return trimmed
        }
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { throw NebiusError.emptyCompletion }
            return joined
        }
        throw NebiusError.invalidResponse
    }
}
