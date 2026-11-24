import XCTest
@testable import ARTracker
import ARTrackerNative

final class ProcessTimesTests: XCTestCase {
    func testConvertsWallClockStartToUptime() {
        let t = ProcessTimes.from(constructorUptimeNs: 5_000_000_000, constructorWallUs: 1_000_300_000, processStartWallUs: 1_000_000_000)
        XCTAssertEqual(t.processStartNs, 4_700_000_000)
        XCTAssertEqual(t.preMainEndNs, 5_000_000_000)
    }

    func testStartAfterConstructorIsNil() {
        let t = ProcessTimes.from(constructorUptimeNs: 5_000_000_000, constructorWallUs: 1_000_000_000, processStartWallUs: 1_000_000_500)
        XCTAssertNil(t.processStartNs)
    }

    func testDeltaExceedingConstructorUptimeReturnsNil() {
        // NTP jump or clock skew: process start too far in past
        let t = ProcessTimes.from(constructorUptimeNs: 1_000_000_000, constructorWallUs: 1_005_000_000, processStartWallUs: 1_000_000_000)
        XCTAssertNil(t.processStartNs)
    }

    func testRealProcessHasPlausibleTimes() {
        let t = ProcessTimes.current()
        XCTAssertNotNil(t.processStartNs)
        XCTAssertLessThanOrEqual(t.processStartNs!, t.preMainEndNs!)
        XCTAssertGreaterThan(artn_now_ns(), t.preMainEndNs!)
        XCTAssertGreaterThan(artn_constructor_uptime_ns(), 0)
    }
}
