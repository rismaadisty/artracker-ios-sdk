import Foundation

public final class SessionManager: @unchecked Sendable {
    public static let shared = SessionManager()

    private let lock = UnfairLock()
    private var _sessionId: String
    private var _userId: String?
    private var _lastActivity: TimeInterval
    private let idleTimeout: TimeInterval = 1800 // 30 minutes

    public init() {
        self._sessionId = Self.generateSessionId()
        self._lastActivity = ProcessInfo.processInfo.systemUptime
    }

    public var sessionId: String {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            if now - _lastActivity > idleTimeout {
                _sessionId = Self.generateSessionId()
            }
            _lastActivity = now
            return _sessionId
        }
    }

    public var userId: String? {
        get { lock.withLock { _userId } }
        set { lock.withLock { _userId = newValue } }
    }

    public func touch() {
        lock.withLock {
            _lastActivity = ProcessInfo.processInfo.systemUptime
        }
    }

    public func rotateSession() -> String {
        lock.withLock {
            _sessionId = Self.generateSessionId()
            _lastActivity = ProcessInfo.processInfo.systemUptime
            return _sessionId
        }
    }

    public static func generateSessionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "ses_" + hex
    }
}

