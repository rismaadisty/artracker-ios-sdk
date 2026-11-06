import Foundation
import Darwin

public struct TrackerMetricsSummary: Sendable, CustomStringConvertible {
    public let queueDepth: Int
    public let sentCount: Int
    public let droppedCount: Int
    public let cpuTimeMs: Double
    public let launchPhaseAMs: Double

    public var description: String {
        "TrackerMetrics(queue: \(queueDepth), sent: \(sentCount), dropped: \(droppedCount), cpu: \(String(format: "%.2f", cpuTimeMs))ms, launchA: \(String(format: "%.2f", launchPhaseAMs))ms)"
    }
}

public final class Metrics: @unchecked Sendable {
    public static let shared = Metrics()

    private let lock = UnfairLock()
    private var _sentCount: Int = 0
    private var _droppedCount: Int = 0

    public func incrementSent(by count: Int = 1) {
        lock.withLock { _sentCount += count }
    }

    public func incrementDropped(by count: Int = 1) {
        lock.withLock { _droppedCount += count }
    }

    public func snapshot(queueDepth: Int, launchPhaseAMs: Double) -> TrackerMetricsSummary {
        lock.withLock {
            TrackerMetricsSummary(
                queueDepth: queueDepth,
                sentCount: _sentCount,
                droppedCount: _droppedCount,
                cpuTimeMs: Self.currentProcessCPUTimeMs(),
                launchPhaseAMs: launchPhaseAMs
            )
        }
    }

    public static func currentProcessCPUTimeMs() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0.0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(threadCount * UInt32(MemoryLayout<thread_t>.stride)))
        }

        var totalMicroseconds: UInt64 = 0
        let basicInfoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)

        for i in 0..<Int(threadCount) {
            var basicInfo = thread_basic_info()
            var count = basicInfoCount
            let threadResult = withUnsafeMutablePointer(to: &basicInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if threadResult == KERN_SUCCESS {
                totalMicroseconds += UInt64(basicInfo.user_time.seconds) * 1_000_000 + UInt64(basicInfo.user_time.microseconds)
                totalMicroseconds += UInt64(basicInfo.system_time.seconds) * 1_000_000 + UInt64(basicInfo.system_time.microseconds)
            }
        }
        return Double(totalMicroseconds) / 1000.0
    }
}
