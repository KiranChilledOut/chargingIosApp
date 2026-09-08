import Foundation

/// A JSON value that is `Sendable`, unlike `[String: Any]`.
///
/// Needed because the schemas below are static constants crossing isolation
/// boundaries; a boxed-`Any` dictionary cannot be `Sendable` and is a hard
/// error under the Swift 6 language mode.
public indirect enum JSONValue: Sendable, Equatable, Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }

    /// Foundation-compatible form, for callers outside the encoder path.
    public var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Constrains model output to JSON.
///
/// Nebius supports OpenAI-style `response_format`, which is a far stronger
/// guarantee than asking nicely in the prompt. Not every hosted model
/// implements it, so `NebiusClient` retries once without the parameter if a
/// request is rejected — and `JSONExtraction` remains the second line of
/// defence either way.
///
/// Note the wire shape: Nebius puts the schema *directly* under `json_schema`,
/// not inside OpenAI's newer `{name, strict, schema}` wrapper.
public enum ResponseFormat: Sendable, Equatable, Encodable {
    case jsonObject
    case jsonSchema(JSONValue)

    /// The value as Nebius expects it on the wire.
    var wireValue: JSONValue {
        switch self {
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema(let schema):
            return .object(["type": "json_schema", "json_schema": schema])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The three fixed schemas this app asks models to follow.
public enum Schemas {

    /// Array of `{id, nl, en}` — the translate path.
    public static let translationUnits: JSONValue = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "id": ["type": "integer"],
                "nl": ["type": "string"],
                "en": ["type": "string"],
            ],
            "required": ["id", "nl", "en"],
            "additionalProperties": false,
        ],
    ]

    /// `{summary, actions[], warnings[]}` — the explain path.
    public static let screenExplanation: JSONValue = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "actions": ["type": "array", "items": ["type": "string"]],
            "warnings": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["summary", "actions", "warnings"],
        "additionalProperties": false,
    ]

    /// `{dutch, notes[]}` — the compose path.
    public static let composeResult: JSONValue = [
        "type": "object",
        "properties": [
            "dutch": ["type": "string"],
            "notes": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["dutch", "notes"],
        "additionalProperties": false,
    ]
}
