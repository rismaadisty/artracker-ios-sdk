import Foundation
import os.signpost

public final class LaunchMetrics: @unchecked Sendable {
    public static let shared = LaunchMetrics()

    private let lock = UnfairLock()
    private var phaseAStartUptime: TimeInterval = 0
    private var phaseADurationMs: Double = 0
    private let log = OSLog(subsystem: "id.art.tracker", category: "Launch")

    public func markPhaseAStart() {
        lock.withLock {
            phaseAStartUptime = ProcessInfo.processInfo.systemUptime
            if #available(iOS 12.0, *) {
                os_signpost(.begin, log: log, name: "artracker.configure")
            }
        }
    }

    public func markPhaseAEnd() {
        lock.withLock {
            let duration = (ProcessInfo.processInfo.systemUptime - phaseAStartUptime) * 1000.0
            phaseADurationMs = duration
            if #available(iOS 12.0, *) {
                os_signpost(.end, log: log, name: "artracker.configure")
            }
        }
    }

    public var phaseAMs: Double {
        lock.withLock { phaseADurationMs }
    }
}

