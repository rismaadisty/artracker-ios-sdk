import XCTest
@testable import ARTracker

final class LaunchMetricsTests: XCTestCase {
    func testPhaseAInitializationBudgetGate() {
        var durations: [Double] = []

        for _ in 0..<50 {
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = SessionManager.generateSessionId()
            let config = ARTrackerConfig(environment: "production")
            _ = DeviceContext.capture(config: config)
            let t1 = ProcessInfo.processInfo.systemUptime
            durations.append((t1 - t0) * 1000.0)
        }

        durations.sort()
        let median = durations[durations.count / 2]
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        let minVal = durations.first!
        let maxVal = durations.last!

        print(String(format: "Phase A Benchmark: min=%.3fms median=%.3fms p95=%.3fms max=%.3fms", minVal, median, p95, maxVal))

        // Target: Phase A <= 2.0 ms
        XCTAssertLessThanOrEqual(p95, 2.0, "Phase A p95 initialization time must be <= 2.0ms")
        XCTAssertLessThanOrEqual(median, 1.0, "Phase A median initialization time must be <= 1.0ms")
    }

    func testCPUTimeMeasurement() {
        let store = BreadcrumbStore(capacity: 50)
        for i in 0..<100 {
            store.add(Breadcrumb(message: "Event \(i)"))
        }

        // Measure idle CPU consumption
        let initialCpu = Metrics.currentProcessCPUTimeMs()
        let t0 = ProcessInfo.processInfo.systemUptime

        Thread.sleep(forTimeInterval: 0.1) // 100ms idle

        let t1 = ProcessInfo.processInfo.systemUptime
        let elapsedMs = (t1 - t0) * 1000.0
        let finalCpu = Metrics.currentProcessCPUTimeMs()
        let cpuConsumed = max(0.0, finalCpu - initialCpu)
        let cpuPercent = (cpuConsumed / elapsedMs) * 100.0

        print(String(format: "CPU Consumption (Idle): %.2fms elapsed, %.2fms CPU consumed (%.2f%%)", elapsedMs, cpuConsumed, cpuPercent))
        XCTAssertLessThanOrEqual(cpuPercent, 1.0, "CPU usage during idle must be < 1.0%")
    }
}
