import XCTest
@testable import ARTracker

final class PerfMathTests: XCTestCase {
    func testCpuPercentComputationAndClamping() {
        XCTAssertEqual(PerfMath.cpuPercent(prevCpuMs: 0, nowCpuMs: 1000, elapsedMs: 1000, cores: 4), 25.0)
        XCTAssertNil(PerfMath.cpuPercent(prevCpuMs: 0, nowCpuMs: 100, elapsedMs: 0, cores: 4))
        XCTAssertNil(PerfMath.cpuPercent(prevCpuMs: 0, nowCpuMs: 100, elapsedMs: 1000, cores: 0))
        XCTAssertEqual(PerfMath.cpuPercent(prevCpuMs: 0, nowCpuMs: 99_999, elapsedMs: 1000, cores: 1), 100.0)
        XCTAssertEqual(PerfMath.cpuPercent(prevCpuMs: 500, nowCpuMs: 400, elapsedMs: 1000, cores: 2), 0.0)
    }

    func testThermalStateMapping() {
        XCTAssertEqual(PerfMath.thermalString(.nominal), "nominal")
        XCTAssertEqual(PerfMath.thermalString(.fair), "fair")
        XCTAssertEqual(PerfMath.thermalString(.serious), "serious")
        XCTAssertEqual(PerfMath.thermalString(.critical), "critical")
    }

    func testMachThreadCountAndPhysFootprint() throws {
        let threads = try XCTUnwrap(Metrics.currentThreadCount())
        XCTAssertGreaterThanOrEqual(threads, 1)

        let baseline = try XCTUnwrap(Metrics.physFootprintBytes())
        XCTAssertGreaterThan(baseline, 0)

        let size = 50 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        for idx in stride(from: 0, to: size, by: 4096) {
            buffer[idx] = UInt8(truncatingIfNeeded: idx)
        }

        let delta = withExtendedLifetime(buffer) { () -> UInt64 in
            let after = Metrics.physFootprintBytes() ?? 0
            return after > baseline ? after - baseline : 0
        }
        XCTAssertGreaterThanOrEqual(delta, 40 * 1024 * 1024)
    }
}

