import Foundation

/// A span of sensitive text found in OCR output.
public struct RedactionSpan: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case iban = "IBAN"
        case bsn = "BSN"
        case card = "CARD"
        case email = "EMAIL"
        case phone = "PHONE"
        case postcode = "POSTCODE"
    }

    public let kind: Kind
    public let original: String
    public let placeholder: String
}

/// The result of redacting a batch of text, plus the means to restore it.
public struct RedactionMap: Sendable {
    public private(set) var spans: [String: RedactionSpan] = [:]

    public var isEmpty: Bool { spans.isEmpty }
    public var count: Int { spans.count }

    public var kindsFound: Set<RedactionSpan.Kind> {
        Set(spans.values.map(\.kind))
    }

    fileprivate mutating func add(_ span: RedactionSpan) {
        spans[span.placeholder] = span
    }

    /// Puts the original values back after the model has done its work.
    ///
    /// Deliberately tolerant of the model reformatting the token — `[[R1]]`
    /// may come back as `[[ R1 ]]` or `[[1]]`. Anything still unmatched is
    /// left as-is rather than silently dropped, so a failure is visible.
    public func restore(in text: String) -> String {
        guard !spans.isEmpty else { return text }
        guard let regex = Redactor.placeholderPattern else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let numberRange = Range(match.range(at: 1), in: text) else { continue }
            let index = String(text[numberRange])
            let canonical = "[[R\(index)]]"
            guard let span = spans[canonical] else { continue }

            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += span.original
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

/// Finds and masks personal data before any text leaves the device.
///
/// This exists because the whole point of the app is pointing it at banking,
/// government and insurance screens — exactly the screens whose contents you
/// would not paste into a third-party API. Masking happens before the network
/// call; the originals never leave the process.
public enum Redactor {

    static let placeholderPattern = try? NSRegularExpression(
        pattern: #"\[\[\s*R?(\d+)\s*\]\]"#
    )

    private static let patterns: [(RedactionSpan.Kind, String)] = [
        // IBAN: 2 letters, 2 check digits, then 11-30 alphanumerics, often
        // written with spaces in groups of four.
        (.iban, #"\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#),
        (.email, #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
        // Card numbers: 13-19 digits in groups, separated by space or dash.
        (.card, #"\b(?:[0-9]{4}[ -]?){3}[0-9]{1,7}\b"#),
        // Dutch mobile/landline, international or national form.
        (.phone, #"(?:\+31|0031)[ -]?[1-9][0-9]{1,2}[ -]?[0-9]{6,8}\b|\b0[1-9][0-9]{1,2}[ -]?[0-9]{6,7}\b"#),
        // Dutch postcode: 1234 AB
        (.postcode, #"\b[1-9][0-9]{3}[ ]?[A-Z]{2}\b"#),
        // Bare 9-digit run, candidate BSN. Validated by the 11-proef below.
        (.bsn, #"\b[0-9]{9}\b"#),
    ]

    /// Which categories to mask. Postcode is off by default — it is weakly
    /// identifying on its own and masking it often removes useful context
    /// from an address form the user is trying to read.
    public struct Policy: Sendable {
        public var kinds: Set<RedactionSpan.Kind>

        public init(kinds: Set<RedactionSpan.Kind>) {
            self.kinds = kinds
        }

        public static let standard = Policy(kinds: [.iban, .bsn, .card, .email, .phone])
        public static let strict = Policy(kinds: Set(
            [.iban, .bsn, .card, .email, .phone, .postcode]
        ))
        public static let none = Policy(kinds: [])
    }

    /// Masks sensitive spans across a batch of blocks, sharing one placeholder
    /// namespace so the same value in two blocks maps to the same token.
    public static func redact(
        blocks: [TextBlock],
        policy: Policy = .standard
    ) -> (blocks: [TextBlock], map: RedactionMap) {
        guard !policy.kinds.isEmpty else { return (blocks, RedactionMap()) }

        var map = RedactionMap()
        var assigned: [String: String] = [:]
        var counter = 0

        let redacted = blocks.map { block -> TextBlock in
            var copy = block
            copy.text = redact(
                text: block.text,
                policy: policy,
                assigned: &assigned,
                counter: &counter,
                map: &map
            )
            return copy
        }
        return (redacted, map)
    }

    /// Masks a single string. Exposed for the compose path, which has no blocks.
    public static func redact(
        text: String,
        policy: Policy = .standard
    ) -> (text: String, map: RedactionMap) {
        var map = RedactionMap()
        var assigned: [String: String] = [:]
        var counter = 0
        let out = redact(
            text: text, policy: policy, assigned: &assigned,
            counter: &counter, map: &map
        )
        return (out, map)
    }

    private static func redact(
        text: String,
        policy: Policy,
        assigned: inout [String: String],
        counter: inout Int,
        map: inout RedactionMap
    ) -> String {
        var candidates: [(range: NSRange, kind: RedactionSpan.Kind, value: String)] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        for (kind, pattern) in patterns where policy.kinds.contains(kind) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: full) {
                let value = ns.substring(with: match.range)
                guard passesChecksum(value, kind: kind) else { continue }
                candidates.append((match.range, kind, value))
            }
        }
        guard !candidates.isEmpty else { return text }

        // Longer matches win: an IBAN must not be shredded by the card or BSN
        // pattern matching a slice of its digits.
        candidates.sort {
            $0.range.length != $1.range.length
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }

        var claimed: [NSRange] = []
        var accepted: [(range: NSRange, kind: RedactionSpan.Kind, value: String)] = []
        for candidate in candidates {
            let overlaps = claimed.contains { NSIntersectionRange($0, candidate.range).length > 0 }
            if overlaps { continue }
            claimed.append(candidate.range)
            accepted.append(candidate)
        }

        accepted.sort { $0.range.location < $1.range.location }

        var result = ""
        var cursor = 0
        for item in accepted {
            let placeholder: String
            if let existing = assigned[item.value] {
                placeholder = existing
            } else {
                counter += 1
                placeholder = "[[R\(counter)]]"
                assigned[item.value] = placeholder
                map.add(RedactionSpan(
                    kind: item.kind, original: item.value, placeholder: placeholder
                ))
            }
            result += ns.substring(with: NSRange(
                location: cursor, length: item.range.location - cursor
            ))
            result += placeholder
            cursor = item.range.location + item.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func passesChecksum(_ value: String, kind: RedactionSpan.Kind) -> Bool {
        switch kind {
        case .bsn: return isValidBSN(value)
        case .iban: return isValidIBAN(value)
        case .card: return isValidLuhn(value)
        case .email, .phone, .postcode: return true
        }
    }

    /// Dutch BSN "elfproef": weights 9…2 then −1, sum divisible by 11.
    ///
    /// Without this every 9-digit order number and product code on screen
    /// would be masked, which would make the translation useless.
    public static func isValidBSN(_ value: String) -> Bool {
        let digits = value.compactMap { $0.wholeNumberValue }
        guard digits.count == 9 else { return false }
        // An all-zero run passes the arithmetic but is never a real BSN.
        guard digits.contains(where: { $0 != 0 }) else { return false }

        var sum = 0
        for (index, digit) in digits.enumerated() {
            let weight = index == 8 ? -1 : 9 - index
            sum += digit * weight
        }
        return sum % 11 == 0
    }

    /// ISO 13616 mod-97 check.
    public static func isValidIBAN(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: " ", with: "").uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }

        let chars = Array(compact)
        guard chars[0].isLetter, chars[1].isLetter,
              chars[2].isNumber, chars[3].isNumber else { return false }

        let rearranged = String(chars[4...]) + String(chars[0..<4])
        var remainder = 0
        for ch in rearranged {
            let piece: Int
            if let digit = ch.wholeNumberValue, ch.isNumber {
                piece = digit
                remainder = (remainder * 10 + piece) % 97
            } else if ch.isLetter, let ascii = ch.asciiValue {
                piece = Int(ascii - 65) + 10
                remainder = (remainder * 100 + piece) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// Luhn check for card numbers.
    public static func isValidLuhn(_ value: String) -> Bool {
        let digits = value.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }

        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
