import Foundation
@testable import NLLensCore

/// Records requests and replays canned responses, so pipeline tests never
/// touch the network or need an API key.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var body: Data

        static func json(_ string: String, status: Int = 200) -> Stub {
            Stub(statusCode: status, body: Data(string.utf8))
        }

        /// Wraps assistant text in an OpenAI-shaped chat completion envelope.
        static func completion(_ content: String) -> Stub {
            let payload: [String: Any] = [
                "choices": [["message": ["role": "assistant", "content": content]]]
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return Stub(statusCode: 200, body: data)
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private(set) var requests: [HTTPRequest] = []
    /// Transport-level failures to throw before consuming stubs.
    private var failuresRemaining: Int

    init(stubs: [Stub], failuresRemaining: Int = 0) {
        self.stubs = stubs
        self.failuresRemaining = failuresRemaining
    }

    convenience init(completion: String) {
        self.init(stubs: [.completion(completion)])
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    func recordedBodies() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { String(data: $0.body ?? Data(), encoding: .utf8) ?? "" }
    }

    struct SimulatedFailure: Error {}

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            lock.unlock()
            throw SimulatedFailure()
        }
        let stub = stubs.isEmpty ? nil : stubs.removeFirst()
        lock.unlock()

        guard let stub else {
            return HTTPResponse(statusCode: 500, body: Data("{}".utf8))
        }
        return HTTPResponse(statusCode: stub.statusCode, body: stub.body)
    }
}

extension NebiusConfiguration {
    static func test(maxRetries: Int = 2) -> NebiusConfiguration {
        NebiusConfiguration(
            apiKey: "test-key",
            textModel: "test/text-model",
            visionModel: "test/vision-model",
            requestTimeout: 5,
            maxRetries: maxRetries
        )
    }
}

extension NebiusClient {
    /// Client with instant backoff, so retry tests run in milliseconds.
    static func test(
        transport: any HTTPTransport,
        maxRetries: Int = 2
    ) -> NebiusClient {
        NebiusClient(
            configuration: .test(maxRetries: maxRetries),
            transport: transport,
            sleeper: { _ in }
        )
    }
}

func temporaryCacheURL(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nllens-tests", isDirectory: true)
        .appendingPathComponent("\(name).jsonl")
}
