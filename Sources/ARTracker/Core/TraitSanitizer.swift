import Foundation

public enum TraitSanitizer {
    public static let maxKeys = 50
    public static let maxKeyLength = 64
    public static let maxValueLength = 256

    private static let sensitiveKeyRegex = try? NSRegularExpression(
        pattern: #"(?i)(pass(word)?|secret|token|api[_-]?key|authorization|cookie|card|cvv|pin|nik|ssn)"#
    )

    public static func sanitize(_ traits: [String: Any]) -> [String: JSONValue] {
        var filtered: [String: JSONValue] = [:]

        for (k, v) in traits {
            // Validate key length: 1..64
            if k.isEmpty || k.count > maxKeyLength {
                continue
            }

            // Sensitive key drop
            if let regex = sensitiveKeyRegex {
                let range = NSRange(location: 0, length: k.utf16.count)
                if regex.firstMatch(in: k, range: range) != nil {
                    continue
                }
            }

            // Value sanitization
            if let jsonVal = sanitizeValue(v) {
                filtered[k] = jsonVal
            }
        }

        // Cap at 50 keys after filtering, selected by sorted key order
        let sortedKeys = filtered.keys.sorted()
        let cappedKeys = sortedKeys.prefix(maxKeys)

        var result: [String: JSONValue] = [:]
        for key in cappedKeys {
            result[key] = filtered[key]
        }
        return result
    }

    private static func sanitizeValue(_ value: Any) -> JSONValue? {
        if value is NSNull {
            return .null
        }

        if let str = value as? String {
            return .string(String(str.prefix(maxValueLength)))
        }

        // Check for boolean first: NSNumber bridged bools vs Swift Bool
        let ref = value as CFTypeRef
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            if let boolVal = value as? Bool {
                return .bool(boolVal)
            }
            if let num = value as? NSNumber {
                return .bool(num.boolValue)
            }
        }

        if let boolVal = value as? Bool {
            return .bool(boolVal)
        }

        if let num = value as? NSNumber {
            let doubleVal = num.doubleValue
            guard doubleVal.isFinite else { return nil }
            return .number(doubleVal)
        }

        if let d = value as? Double {
            guard d.isFinite else { return nil }
            return .number(d)
        }

        if let f = value as? Float {
            guard f.isFinite else { return nil }
            return .number(Double(f))
        }

        if let i = value as? Int {
            return .number(Double(i))
        }

        if let i = value as? Int64 {
            return .number(Double(i))
        }

        // Drop nested objects, arrays, Dates, and anything else
        return nil
    }
}
