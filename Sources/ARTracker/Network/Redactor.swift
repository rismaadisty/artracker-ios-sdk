import Foundation

public struct RedactedURLInfo: Sendable {
    public let host: String
    public let path: String
    public let sanitizedURL: String
}

public struct Redactor {
    private static let sensitiveHeaders: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-artracker-key",
        "proxy-authorization"
    ]

    public static func sanitize(url: URL) -> RedactedURLInfo {
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let sanitized = "\(url.scheme ?? "https")://\(host)\(path)"
        return RedactedURLInfo(host: host, path: path, sanitizedURL: sanitized)
    }

    public static func sanitizeHeaders(_ headers: [String: String]?) -> [String: String] {
        guard let headers = headers else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in headers {
            if sensitiveHeaders.contains(key.lowercased()) {
                result[key] = "[REDACTED]"
            } else {
                result[key] = value
            }
        }
        return result
    }
}

