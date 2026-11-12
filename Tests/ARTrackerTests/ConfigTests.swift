import XCTest
@testable import ARTracker

final class ConfigTests: XCTestCase {
    func testPerformanceConfigDefaultsAndClamping() {
        let defaultConfig = ARTrackerConfig()
        XCTAssertFalse(defaultConfig.enablePerformanceMonitoring)
        XCTAssertEqual(defaultConfig.performanceSampleInterval, 1.0)

        let tooLow = ARTrackerConfig(performanceSampleInterval: 0.1)
        XCTAssertEqual(tooLow.performanceSampleInterval, 0.5)

        let tooHigh = ARTrackerConfig(performanceSampleInterval: 30.0)
        XCTAssertEqual(tooHigh.performanceSampleInterval, 10.0)
    }

    func testPerfItemTypeEncoding() throws {
        XCTAssertEqual(ItemType.perf.rawValue, "perf")

        let item = Item(type: .perf, name: "perf.samples")
        let data = try JSONEncoder().encode(item)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\"type\":\"perf\""))
    }
}

