import XCTest
@testable import NLLensCore

/// Pins the exact request shape against what Nebius documents.
///
/// These assertions exist because the whole app fails silently if the body
/// drifts: a schema nested one level too deep, or a base64 payload mangled by
/// slash escaping, produces a 400 with no obvious cause.
final class WireShapeTests: XCTestCase {

    private func body(
        messages: [ChatMessage],
        model: String = "test/model",
        responseFormat: ResponseFormat? = nil
    ) throws -> [String: Any] {
        let client = NebiusClient.test(transport: MockTransport(stubs: []))
        let data = try client.encodeRequestBody(
            messages: messages, model: model,
            temperature: 0.1, maxTokens: 128, responseFormat: responseFormat
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testTopLevelKeys() throws {
        let object = try body(messages: [.user("hi")])
        XCTAssertEqual(object["model"] as? String, "test/model")
        XCTAssertEqual(object["max_tokens"] as? Int, 128)
        XCTAssertNotNil(object["messages"])
        XCTAssertNil(object["response_format"], "omitted when not requested")
    }

    func testSchemaSitsDirectlyUnderJSONSchemaKey() throws {
        // Nebius takes the schema itself here, NOT OpenAI's newer
        // {name, strict, schema} wrapper. Getting this wrong is a 400.
        let object = try body(
            messages: [.user("hi")],
            responseFormat: .jsonSchema(Schemas.translationUnits)
        )
        let format = try XCTUnwrap(object["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")

        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "array")
        XCTAssertNil(schema["schema"], "must not be double-wrapped")
        XCTAssertNil(schema["name"], "Nebius does not use the name wrapper")

        let items = try XCTUnwrap(schema["items"] as? [String: Any])
        let required = try XCTUnwrap(items["required"] as? [String])
        XCTAssertEqual(Set(required), ["id", "nl", "en"])
    }

    func testTextOnlyMessageUsesStringContent() throws {
        let object = try body(messages: [.user("plain text")])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "plain text")
    }

    func testMultimodalMessageUsesPartsArray() throws {
        let object = try body(messages: [
            ChatMessage(role: .user, content: [
                .imageBase64("QUJD", mimeType: "image/jpeg"),
                .text("Explain"),
            ])
        ])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")

        let imageURL = try XCTUnwrap(parts[0]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,QUJD")
        XCTAssertEqual(parts[1]["type"] as? String, "text")
    }

    func testBase64SlashesAreNotEscaped() throws {
        // Base64 alphabet includes "/", and a screenshot payload is full of it.
        // Escaping is legal JSON but bloats the body, so the encoder is
        // configured with .withoutEscapingSlashes — assert it stays that way.
        let client = NebiusClient.test(transport: MockTransport(stubs: []))
        let data = try client.encodeRequestBody(
            messages: [ChatMessage(role: .user, content: [
                .imageBase64("AA//BB", mimeType: "image/jpeg")
            ])],
            model: "vendor/model", temperature: 0, maxTokens: 16
        )
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("data:image/jpeg;base64,AA//BB"), raw)
        XCTAssertTrue(raw.contains("vendor/model"))
        XCTAssertFalse(raw.contains("\\/"), "no escaped slashes anywhere")
    }

    func testEndpointPathsAreCorrect() {
        let base = NebiusConfiguration.defaultBaseURL
        XCTAssertEqual(
            base.appendingPathComponent("chat/completions").absoluteString,
            "https://api.tokenfactory.nebius.com/v1/chat/completions"
        )
        XCTAssertEqual(
            base.appendingPathComponent("models").absoluteString,
            "https://api.tokenfactory.nebius.com/v1/models"
        )
    }
}
