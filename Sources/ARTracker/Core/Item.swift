import Foundation

public enum ItemType: String, Codable, Sendable {
    case event
    case log
    case session
}

public enum ItemLevel: String, Codable, Sendable {
    case debug
    case info
    case warn
    case error
    case fatal
}

public struct Item: Codable, Sendable, Equatable {
    public let id: String
    public let type: ItemType
    public let name: String
    public let level: ItemLevel?
    public let message: String?
    public let timestamp: String
    public let sessionId: String?
    public let userId: String?
    public let attributes: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case level
        case message
        case timestamp
        case sessionId = "session_id"
        case userId = "user_id"
        case attributes
    }

    public init(
        id: String = "itm_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
        type: ItemType,
        name: String,
        level: ItemLevel? = nil,
        message: String? = nil,
        timestamp: String? = nil,
        sessionId: String? = nil,
        userId: String? = nil,
        attributes: [String: JSONValue] = [:]
    ) {
        self.id = String(id.prefix(128))
        self.type = type
        self.name = String(name.prefix(255))
        self.level = level
        self.message = message.map { String($0.prefix(4096)) }
        self.timestamp = timestamp ?? DefaultClock.shared.nowISO8601()
        self.sessionId = sessionId.map { String($0.prefix(128)) }
        self.userId = userId.map { String($0.prefix(128)) }
        self.attributes = Self.enforceAttributeCap(attributes)
    }

    /// Backend hard-limit: attributes must be <= 32 KB (32,768 bytes).
    private static func enforceAttributeCap(_ attrs: [String: JSONValue]) -> [String: JSONValue] {
        guard !attrs.isEmpty else { return attrs }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(attrs), data.count <= 32_000 {
            return attrs
        }
        var sanitized = attrs
        if let stack = sanitized["stack_trace"], case .string(let s) = stack {
            sanitized["stack_trace"] = .string(String(s.prefix(10_000)) + "\n...[truncated]")
        }
        if let crumbs = sanitized["breadcrumbs"], case .array(let arr) = crumbs, arr.count > 20 {
            sanitized["breadcrumbs"] = .array(Array(arr.suffix(20)))
        }
        if let data = try? encoder.encode(sanitized), data.count <= 32_000 {
            return sanitized
        }
        return [
            "_truncated": .bool(true),
            "_error": .string("attributes exceeded 32KB limit")
        ]
    }
}

