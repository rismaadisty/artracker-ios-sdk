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
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
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

    public static func currentThreadCount() -> Int? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return nil }
        defer {
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }
        return Int(threadCount)
    }

    public static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    public static func freeRamBytesSample() -> (free: UInt64, inactive: UInt64, speculative: UInt64, pageSize: UInt64)? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            free: UInt64(vmStats.free_count),
            inactive: UInt64(vmStats.inactive_count),
            speculative: UInt64(vmStats.speculative_count),
            pageSize: UInt64(pageSize)
        )
    }

    public static func storageCapacities() -> (freeBytes: Int64?, totalBytes: Int64?) {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            let totalBytes = values.volumeTotalCapacity.flatMap { $0 > 0 ? Int64($0) : nil }
            let importantFree = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            let basicFree = values.volumeAvailableCapacity.flatMap { $0 > 0 ? Int64($0) : nil }
            let freeBytes = importantFree ?? basicFree
            if totalBytes != nil || freeBytes != nil {
                return (freeBytes: freeBytes, totalBytes: totalBytes)
            }
        }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: homeURL.path) {
            let totalNum = (attrs[.systemSize] as? NSNumber)?.int64Value
            let freeNum = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            return (
                freeBytes: freeNum.flatMap { $0 > 0 ? $0 : nil },
                totalBytes: totalNum.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return (freeBytes: nil, totalBytes: nil)
    }

    public static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceFacts.osVersionString(
            major: v.majorVersion,
            minor: v.minorVersion,
            patch: v.patchVersion
        )
    }
}
