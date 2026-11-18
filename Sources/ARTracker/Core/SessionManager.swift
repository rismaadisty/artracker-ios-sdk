import Foundation

internal protocol SessionLifecycleListener: AnyObject, Sendable {
    func sessionDidStart(id: String)
    func sessionDidEnd(id: String, durationMs: Double)
}

public final class SessionManager: @unchecked Sendable {
    public static let shared = SessionManager()

    private let lock = UnfairLock()
    private let clock: @Sendable () -> TimeInterval
    private let userDefaults: UserDefaults?
    private var _sessionId: String
    private var _userId: String?
    private var _startedAt: TimeInterval
    private var _lastActivity: TimeInterval
    private var _lastPersistedAt: TimeInterval = 0
    private var _idleTimeout: TimeInterval
    private let maxDuration: TimeInterval = 86_400 // 24 hours
    private let persistInterval: TimeInterval = 60.0 // 60 seconds (parity with Android PERSIST_INTERVAL_MS)

    internal var idleTimeout: TimeInterval {
        lock.withLock { _idleTimeout }
    }

    private var pendingRestoredSessionEnd: (id: String, durationMs: Double)?

    internal weak var listener: SessionLifecycleListener? {
        didSet {
            let pending = lock.withLock { () -> (id: String, durationMs: Double)? in
                let p = pendingRestoredSessionEnd
                pendingRestoredSessionEnd = nil
                return p
            }
            if let p = pending {
                listener?.sessionDidEnd(id: p.id, durationMs: p.durationMs)
                let currentId = lock.withLock { _sessionId }
                listener?.sessionDidStart(id: currentId)
            }
        }
    }

    public convenience init() {
        self.init(clock: { Date().timeIntervalSince1970 }, userDefaults: .standard)
    }

    internal convenience init(
        uptime: @escaping @Sendable () -> TimeInterval,
        idleTimeout: TimeInterval = ARTrackerConfig.defaultSessionTimeout
    ) {
        self.init(clock: uptime, userDefaults: nil, idleTimeout: idleTimeout)
    }

    internal init(
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        userDefaults: UserDefaults? = .standard,
        idleTimeout: TimeInterval? = nil
    ) {
        self.clock = clock
        self.userDefaults = userDefaults

        let initialIdleTimeout: TimeInterval
        if let timeout = idleTimeout {
            initialIdleTimeout = ARTrackerConfig.normalizedSessionTimeout(timeout)
        } else if let defs = userDefaults, defs.double(forKey: "artracker.session.idle_timeout") > 0 {
            initialIdleTimeout = ARTrackerConfig.normalizedSessionTimeout(defs.double(forKey: "artracker.session.idle_timeout"))
        } else {
            initialIdleTimeout = ARTrackerConfig.defaultSessionTimeout
        }
        self._idleTimeout = initialIdleTimeout
        if let defs = userDefaults, idleTimeout != nil {
            defs.set(initialIdleTimeout, forKey: "artracker.session.idle_timeout")
        }

        let now = clock()

        if let defs = userDefaults,
           let storedId = defs.string(forKey: "artracker.session.id"),
           !storedId.isEmpty {
            let storedStartedAt = defs.double(forKey: "artracker.session.started_at")
            let storedLastActivity = defs.double(forKey: "artracker.session.last_activity")
            let elapsed = max(0, now - storedLastActivity)

            if elapsed <= _idleTimeout && (now - storedStartedAt < maxDuration) && storedStartedAt > 0 {
                // Restore valid unexpired session
                self._sessionId = storedId
                self._startedAt = storedStartedAt
                self._lastActivity = storedLastActivity
                self._lastPersistedAt = storedLastActivity
                self.pendingRestoredSessionEnd = nil
            } else {
                // Stored session has expired
                let durationMs = max(0, (storedLastActivity - storedStartedAt) * 1000.0)
                self.pendingRestoredSessionEnd = (storedId, durationMs)
                let newId = Self.generateSessionId()
                self._sessionId = newId
                self._startedAt = now
                self._lastActivity = now
                self._lastPersistedAt = now
                defs.set(newId, forKey: "artracker.session.id")
                defs.set(now, forKey: "artracker.session.started_at")
                defs.set(now, forKey: "artracker.session.last_activity")
            }
        } else {
            let newId = Self.generateSessionId()
            self._sessionId = newId
            self._startedAt = now
            self._lastActivity = now
            self._lastPersistedAt = now
            self.pendingRestoredSessionEnd = nil
            if let defs = userDefaults {
                defs.set(newId, forKey: "artracker.session.id")
                defs.set(now, forKey: "artracker.session.started_at")
                defs.set(now, forKey: "artracker.session.last_activity")
            }
        }
    }

    public var sessionId: String {
        var endToNotify: (id: String, durationMs: Double)?
        var startToNotify: String?

        let id = lock.withLock { () -> String in
            let now = clock()
            let expired = max(0, now - _lastActivity) > _idleTimeout
            // Rotate on the 24 h cap only when !isExpired
            if !expired && (now - _startedAt >= maxDuration) {
                let oldId = _sessionId
                let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
                _sessionId = Self.generateSessionId()
                _startedAt = now
                persistLocked(now: now)
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
            max(0, clock() - _lastActivity) > _idleTimeout
        }
    }

    /// Records user interaction, rotating session if expired or max duration cap is reached.
    public func recordUserActivity() {
        var endToNotify: (id: String, durationMs: Double)?
        var startToNotify: String?

        lock.withLock {
            let now = clock()
            let expired = max(0, now - _lastActivity) > _idleTimeout
            let hitCap = now - _startedAt >= maxDuration

            if expired || hitCap {
                let oldId = _sessionId
                let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
                _sessionId = Self.generateSessionId()
                _startedAt = now
                endToNotify = (oldId, durationMs)
                startToNotify = _sessionId
                persistLocked(now: now)
            }
            _lastActivity = now
            if now - _lastPersistedAt >= persistInterval {
                persistLocked(now: now)
            }
        }

        if let end = endToNotify {
            listener?.sessionDidEnd(id: end.id, durationMs: end.durationMs)
        }
        if let start = startToNotify {
            listener?.sessionDidStart(id: start)
        }
    }

    /// Called on app foreground return, delegating to user activity recording.
    public func onForeground() {
        recordUserActivity()
    }

    /// Reconfigures idle timeout, persisting it and rotating if currently active session is expired under new timeout.
    internal func configure(idleTimeout: TimeInterval) {
        let normalized = ARTrackerConfig.normalizedSessionTimeout(idleTimeout)
        var endToNotify: (id: String, durationMs: Double)?
        var startToNotify: String?

        lock.withLock {
            _idleTimeout = normalized
            userDefaults?.set(normalized, forKey: "artracker.session.idle_timeout")

            let now = clock()
            let expired = max(0, now - _lastActivity) > _idleTimeout
            if expired {
                let oldId = _sessionId
                let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
                _sessionId = Self.generateSessionId()
                _startedAt = now
                _lastActivity = now
                persistLocked(now: now)
                if listener != nil {
                    endToNotify = (oldId, durationMs)
                    startToNotify = _sessionId
                } else {
                    pendingRestoredSessionEnd = (oldId, durationMs)
                }
            }
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
            let now = clock()
            if max(0, now - _lastActivity) > _idleTimeout {
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
            let now = clock()
            let oldId = _sessionId
            let durationMs = max(0, (_lastActivity - _startedAt) * 1000.0)
            _sessionId = Self.generateSessionId()
            _startedAt = now
            _lastActivity = now
            persistLocked(now: now)
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

    private func persistLocked(now: TimeInterval) {
        guard let defs = userDefaults else { return }
        defs.set(_sessionId, forKey: "artracker.session.id")
        defs.set(_startedAt, forKey: "artracker.session.started_at")
        defs.set(_lastActivity, forKey: "artracker.session.last_activity")
        _lastPersistedAt = now
    }

    public func persistSession(forced: Bool = false) {
        lock.withLock {
            let now = clock()
            if forced || (now - _lastPersistedAt >= persistInterval) {
                persistLocked(now: now)
            }
        }
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
