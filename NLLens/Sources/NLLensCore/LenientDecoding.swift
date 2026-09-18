import Foundation

/// Reading model output that nearly matches the shape it was asked for.
///
/// A JSON Schema is a request, not a guarantee, and vision models drift from
/// it more than text models do: a lone item arrives as a bare string instead
/// of a one-element array, lists arrive as objects with a `text` key, empty
/// sections are omitted rather than sent as `[]`. Synthesized decoding throws
/// on every one of those, and the user sees an error for a reply that was
/// perfectly usable.
enum Lenient {

    /// A string that may have arrived under one of several keys, or as an
    /// array that should be joined.
    static func string<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        forKeys keys: [K]
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key),
               !value.isEmpty {
                return value
            }
            if let values = try? container.decode([String].self, forKey: key),
               !values.isEmpty {
                return values.joined(separator: " ")
            }
        }
        return nil
    }

    /// A list that may have arrived as a bare string, as objects, or not at all.
    static func stringList<K: CodingKey>(
        in container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values.filter { !$0.isEmpty }
        }
        if let single = try? container.decode(String.self, forKey: key) {
            return single.isEmpty ? [] : [single]
        }
        if let objects = try? container.decode([[String: String]].self, forKey: key) {
            return objects.compactMap { object in
                object["text"] ?? object["action"] ?? object["warning"]
                    ?? object["signal"] ?? object["description"] ?? object.values.first
            }.filter { !$0.isEmpty }
        }
        return []
    }
}
