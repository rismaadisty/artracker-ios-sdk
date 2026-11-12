import Foundation

public final class SessionManager: @unchecked Sendable {
    public static let shared = SessionManager()

    private let lock = UnfairLock()
    private let uptime: @Sendable () -> TimeInterval
    private var _sessionId: String
    private var _userId: String?
    private var _lastActivity: TimeInterval
    private let idleTimeout: TimeInterval = 1800 // 30 minutes

    public convenience init() {
        self.init(uptime: { ProcessInfo.processInfo.systemUptime })
    }

    internal init(uptime: @escaping @Sendable () -> TimeInterval) {
        self.uptime = uptime
        self._sessionId = Self.generateSessionId()
        self._lastActivity = uptime()
    }

    public var sessionId: String {
        lock.withLock {
            let now = uptime()
            if now - _lastActivity > idleTimeout {
                _sessionId = Self.generateSessionId()
            }
            _lastActivity = now
            return _sessionId
        }
    }

    /// Returns the current session ID if not idle-expired, without rotating or refreshing activity.
    public func peekSessionId() -> String? {
        lock.withLock {
            let now = uptime()
            if now - _lastActivity > idleTimeout {
                return nil
            }
            return _sessionId
        }
    }

    public var userId: String? {
        get { lock.withLock { _userId } }
        set { lock.withLock { _userId = newValue } }
    }

    public func touch() {
        lock.withLock {
            _lastActivity = uptime()
        }
    }

    public func rotateSession() -> String {
        lock.withLock {
            _sessionId = Self.generateSessionId()
            _lastActivity = uptime()
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

