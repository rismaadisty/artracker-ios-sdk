import Foundation

internal protocol SessionLifecycleListener: AnyObject, Sendable {
    func sessionDidStart(id: String)
    func sessionDidEnd(id: String, durationMs: Double)
}

public final class SessionManager: @unchecked Sendable {
    public static let shared = SessionManager()

    private let lock = UnfairLock()
    private let uptime: @Sendable () -> TimeInterval
    private var _sessionId: String
    private var _userId: String?
    private var _startedAt: TimeInterval
    private var _lastActivity: TimeInterval
    private let idleTimeout: TimeInterval = 1800 // 30 minutes
    private let maxDuration: TimeInterval = 86_400 // 24 hours

    internal weak var listener: SessionLifecycleListener?

    public convenience init() {
        self.init(uptime: {
            Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000.0
        })
    }

    internal init(uptime: @escaping @Sendable () -> TimeInterval) {
        self.uptime = uptime
        self._sessionId = Self.generateSessionId()
        let now = uptime()
        self._startedAt = now
        self._lastActivity = now
    }

    public var sessionId: String {
        var endToNotify: (id: String, durationMs: Double)?
        var startToNotify: String?

        let id = lock.withLock { () -> String in
            let now = uptime()
            let expired = max(0, now - _lastActivity) > idleTimeout
            // Rotate on the 24 h cap only when !isExpired
            if !expired && (now - _startedAt >= maxDuration) {
                let oldId = _sessionId
                let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
                _sessionId = Self.generateSessionId()
                _startedAt = now
                endToNotify = (oldId, durationMs)
                startToNotify = _sessionId
            }
            return _sessionId
        }

        if let end = endToNotify {
            listener?.sessionDidEnd(id: end.id, durationMs: end.durationMs)
        }
        if let start = startToNotify {
            listener?.sessionDidStart(id: start)
        }
        return id
    }

    public var isExpired: Bool {
        lock.withLock {
            max(0, uptime() - _lastActivity) > idleTimeout
        }
    }

    /// Records user interaction, rotating session if expired or max duration cap is reached.
    public func recordUserActivity() {
        var endToNotify: (id: String, durationMs: Double)?
        var startToNotify: String?

        lock.withLock {
            let now = uptime()
            let expired = max(0, now - _lastActivity) > idleTimeout
            let hitCap = now - _startedAt >= maxDuration

            if expired || hitCap {
                let oldId = _sessionId
                let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
                _sessionId = Self.generateSessionId()
                _startedAt = now
                endToNotify = (oldId, durationMs)
                startToNotify = _sessionId
            }
            _lastActivity = now
        }

        if let end = endToNotify {
            listener?.sessionDidEnd(id: end.id, durationMs: end.durationMs)
        }
        if let start = startToNotify {
            listener?.sessionDidStart(id: start)
        }
    }

    /// Returns the current session ID if not idle-expired, without rotating or refreshing activity.
    public func peekSessionId() -> String? {
        lock.withLock {
            let now = uptime()
            if max(0, now - _lastActivity) > idleTimeout {
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
        recordUserActivity()
    }

    public func rotateSession() -> String {
        var endToNotify: (id: String, durationMs: Double)?
        var startToNotify: String?

        let id = lock.withLock { () -> String in
            let now = uptime()
            let oldId = _sessionId
            let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
            _sessionId = Self.generateSessionId()
            _startedAt = now
            _lastActivity = now
            endToNotify = (oldId, durationMs)
            startToNotify = _sessionId
            return _sessionId
        }

        if let end = endToNotify {
            listener?.sessionDidEnd(id: end.id, durationMs: end.durationMs)
        }
        if let start = startToNotify {
            listener?.sessionDidStart(id: start)
        }
        return id
    }

    public static func generateSessionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "ses_" + hex
    }

    internal func _testSetExpired() {
        lock.withLock {
            _lastActivity = 0
        }
    }
}
