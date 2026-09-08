import Foundation

/// Pulls structured JSON out of whatever a language model actually returns.
///
/// Models wrap JSON in markdown fences, prefix it with "Here's the
/// translation:", and occasionally leave a trailing comma. Any of those makes
/// a plain `JSONDecoder` throw. Since a parse failure here means the user gets
/// nothing back, this is deliberately forgiving.
public enum JSONExtraction {

    public enum Error: Swift.Error, Equatable {
        case noJSONFound
        case decodingFailed(String)
    }

    /// Decodes `T` from a model response, repairing common formatting damage.
    public static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let decoder = JSONDecoder()

        for candidate in candidates(from: raw) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(type, from: data) {
                return decoded
            }
        }

        // Nothing decoded. Report why against the most promising candidate so
        // the error message is actionable rather than just "invalid".
        guard let best = candidates(from: raw).first,
              let data = best.data(using: .utf8) else {
            throw Error.noJSONFound
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }
    }

    /// Ordered list of things worth trying to decode, best guess first.
    static func candidates(from raw: String) -> [String] {
        var out: [String] = []

        func append(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            if !out.contains(value) { out.append(value) }
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        append(trimmed)

        let defenced = stripCodeFences(trimmed)
        append(defenced)

        // Balanced scan finds the payload even with prose on either side.
        append(firstBalancedJSON(in: defenced))
        append(firstBalancedJSON(in: trimmed))

        // Last resort: repair trailing commas in each candidate so far.
        for candidate in out {
            append(repairTrailingCommas(candidate))
        }
        return out
    }

    /// Removes ``` or ```json fences, keeping the fenced body.
    static func stripCodeFences(_ input: String) -> String {
        guard input.contains("```") else { return input }

        var lines = input.components(separatedBy: .newlines)
        var collected: [String] = []
        var inside = false
        var sawFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                sawFence = true
                inside.toggle()
                continue
            }
            if inside { collected.append(line) }
        }

        if sawFence, !collected.isEmpty {
            return collected.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Unbalanced fence: strip the markers and hope the body survives.
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans for the first balanced `{...}` or `[...]`, ignoring braces that
    /// appear inside string literals. This is what survives prose padding.
    static func firstBalancedJSON(in input: String) -> String? {
        let chars = Array(input)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }

        let opener = chars[start]
        let closer: Character = opener == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var escaped = false

        for index in start..<chars.count {
            let ch = chars[index]

            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                // Backslash only escapes inside a string literal.
                if inString { escaped = true }
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }

            if ch == opener {
                depth += 1
            } else if ch == closer {
                depth -= 1
                if depth == 0 {
                    return String(chars[start...index])
                }
            }
        }
        return nil
    }

    /// Removes commas that sit immediately before a closing brace or bracket.
    static func repairTrailingCommas(_ input: String) -> String {
        let chars = Array(input)
        var result: [Character] = []
        result.reserveCapacity(chars.count)

        var inString = false
        var escaped = false

        for (index, ch) in chars.enumerated() {
            if escaped {
                escaped = false
                result.append(ch)
                continue
            }
            if ch == "\\" {
                if inString { escaped = true }
                result.append(ch)
                continue
            }
            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                continue
            }

            if !inString, ch == "," {
                // Look ahead past whitespace for a closer.
                var lookahead = index + 1
                while lookahead < chars.count, chars[lookahead].isWhitespace {
                    lookahead += 1
                }
                if lookahead < chars.count,
                   chars[lookahead] == "}" || chars[lookahead] == "]" {
                    continue  // drop the comma
                }
            }
            result.append(ch)
        }
        return String(result)
    }
}
