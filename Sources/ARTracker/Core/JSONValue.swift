import Foundation

/// Type-safe dynamic JSON representation for attributes and payloads.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .number(let n):
            if n.rounded() == n && !n.isInfinite && !n.isNaN {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .bool(let b):
            try container.encode(b)
        case .object(let dict):
            try container.encode(dict)
        case .array(let arr):
            try container.encode(arr)
        case .null:
            try container.encodeNil()
        }
    }

    public static func from(_ any: Any?) -> JSONValue {
        guard let any = any else { return .null }
        if let val = any as? JSONValue { return val }
        if let s = any as? String { return .string(s) }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .number(Double(i)) }
        if let i = any as? Int64 { return .number(Double(i)) }
        if let d = any as? Double { return .number(d) }
        if let f = any as? Float { return .number(Double(f)) }
        if let arr = any as? [Any] { return .array(arr.map { from($0) }) }
        if let dict = any as? [String: Any] {
            return .object(dict.mapValues { from($0) })
        }
        return .string(String(describing: any))
    }
}

