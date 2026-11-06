import Foundation
import os.log

public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
    case none = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = UnfairLock()
    private var _level: LogLevel = .warn
    private let logger = Logger(subsystem: "id.art.tracker", category: "SDK")

    public var level: LogLevel {
        get { lock.withLock { _level } }
        set { lock.withLock { _level = newValue } }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        if shared.level <= .debug {
            let msg = message()
            shared.logger.debug("🔎 [ARTracker] \(msg, privacy: .public)")
        }
    }

    public static func info(_ message: @autoclosure () -> String) {
        if shared.level <= .info {
            let msg = message()
            shared.logger.info("ℹ️ [ARTracker] \(msg, privacy: .public)")
        }
    }

    public static func warn(_ message: @autoclosure () -> String) {
        if shared.level <= .warn {
            let msg = message()
            shared.logger.warning("⚠️ [ARTracker] \(msg, privacy: .public)")
        }
    }

    public static func error(_ message: @autoclosure () -> String) {
        if shared.level <= .error {
            let msg = message()
            shared.logger.error("❌ [ARTracker] \(msg, privacy: .public)")
        }
    }
}
