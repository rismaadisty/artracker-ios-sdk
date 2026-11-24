import Foundation

/// Rate-limits error-triggered replay buffer promotions per session.
/// Max 3 triggers per session, with at least 60,000 ms gap between admitted triggers.
/// A new sessionId resets both the count and the gap timer.
internal final class ErrorTriggerPolicy: @unchecked Sendable {
    public static let defaultMaxPerSession: Int = 3
    public static let defaultMinGapMs: Int64 = 60_000

    private let maxPerSession: Int
    private let minGapMs: Int64
    private var sessionId: String? = nil
    private var admittedCount: Int = 0
    private var lastAdmittedMs: Int64? = nil

    internal init(
        maxPerSession: Int = ErrorTriggerPolicy.defaultMaxPerSession,
        minGapMs: Int64 = ErrorTriggerPolicy.defaultMinGapMs
    ) {
        self.maxPerSession = maxPerSession
        self.minGapMs = minGapMs
    }

    /// Returns true if the error trigger should promote the buffer now.
    internal func admit(sessionId: String, nowMs: Int64) -> Bool {
        if sessionId != self.sessionId {
            self.sessionId = sessionId
            self.admittedCount = 0
            self.lastAdmittedMs = nil
        }
        if admittedCount >= maxPerSession {
            return false
        }
        if let last = lastAdmittedMs, nowMs - last < minGapMs {
            return false
        }
        admittedCount += 1
        lastAdmittedMs = nowMs
        return true
    }
}
