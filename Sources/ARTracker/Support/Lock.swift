import Darwin

/// Lightweight unfair lock wrapper compatible with iOS 15+ and Swift 6 Sendable concurrency.
public final class UnfairLock: @unchecked Sendable {
    private var _lock: os_unfair_lock = os_unfair_lock()

    public init() {}

    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return try body()
    }
}
