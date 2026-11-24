import XCTest
@testable import ARTracker

final class ConfigTests: XCTestCase {
    func testReplaySampleRateDefaultsToBufferModeAndClamps() {
        let config = ARTrackerConfig()
        XCTAssertEqual(config.replaySampleRate, 0.0)
        XCTAssertEqual(config.replayOnErrorSampleRate, 1.0)

        let clamped = ARTrackerConfig(replaySampleRate: -0.2, replayOnErrorSampleRate: 1.5)
        XCTAssertEqual(clamped.replaySampleRate, 0.0)
        XCTAssertEqual(clamped.replayOnErrorSampleRate, 1.0)

        let nonFinite = ARTrackerConfig(replaySampleRate: .nan, replayOnErrorSampleRate: .infinity)
        XCTAssertEqual(nonFinite.replaySampleRate, 0.0)
        XCTAssertEqual(nonFinite.replayOnErrorSampleRate, 1.0)
    }

    func testPerformanceConfigDefaultsAndClamping() {
        let defaultConfig = ARTrackerConfig()
        XCTAssertFalse(defaultConfig.enablePerformanceMonitoring)
        XCTAssertEqual(defaultConfig.performanceSampleInterval, 1.0)

        let tooLow = ARTrackerConfig(performanceSampleInterval: 0.1)
        XCTAssertEqual(tooLow.performanceSampleInterval, 0.5)

        let tooHigh = ARTrackerConfig(performanceSampleInterval: 30.0)
        XCTAssertEqual(tooHigh.performanceSampleInterval, 10.0)
    }

    func testReplayIdleThresholdClamping() {
        // Defaults: idle 30, dormant 180
        let defaultConfig = ARTrackerConfig()
        XCTAssertEqual(defaultConfig.replayIdleAfter, 30.0)
        XCTAssertEqual(defaultConfig.replayDormantAfter, 180.0)

        // idle 2 -> clamped to 5
        let idleTooLow = ARTrackerConfig(replayIdleAfter: 2.0, replayDormantAfter: 180.0)
        XCTAssertEqual(idleTooLow.replayIdleAfter, 5.0)
        XCTAssertEqual(idleTooLow.replayDormantAfter, 180.0)

        // dormant 5 with idle 30 -> clamped to idle + 1 = 31
        let dormantTooLow = ARTrackerConfig(replayIdleAfter: 30.0, replayDormantAfter: 5.0)
        XCTAssertEqual(dormantTooLow.replayIdleAfter, 30.0)
        XCTAssertEqual(dormantTooLow.replayDormantAfter, 31.0)

        // idle 30 with dormant 30.5 -> 30.5 allowed
        let dormantFractional = ARTrackerConfig(replayIdleAfter: 30.0, replayDormantAfter: 30.5)
        XCTAssertEqual(dormantFractional.replayIdleAfter, 30.0)
        XCTAssertEqual(dormantFractional.replayDormantAfter, 30.5)
    }

    func testPerfItemTypeEncoding() throws {
        XCTAssertEqual(ItemType.perf.rawValue, "perf")

        let item = Item(type: .perf, name: "perf.samples")
        let data = try JSONEncoder().encode(item)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\"type\":\"perf\""))
    }

    func testSessionTimeoutDefaultsToThirtyMinutes() {
        XCTAssertEqual(ARTrackerConfig().sessionTimeout, 1800)
        XCTAssertEqual(ARTrackerConfig.defaultSessionTimeout, 1800)
    }

    func testSessionTimeoutKeepsCustomValue() {
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: 900).sessionTimeout, 900)
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: 1).sessionTimeout, 1)
    }

    func testSessionTimeoutBelowMinimumIsClamped() {
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: 0).sessionTimeout, 1)
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: -5).sessionTimeout, 1)
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: 0.5).sessionTimeout, 1)
    }

    func testSessionTimeoutNonFiniteFallsBackToDefault() {
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: .nan).sessionTimeout, 1800)
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: .infinity).sessionTimeout, 1800)
        XCTAssertEqual(ARTrackerConfig(sessionTimeout: -.infinity).sessionTimeout, 1800)
    }

    func testSessionTimeoutIsMutableAfterInit() {
        var config = ARTrackerConfig()
        config.sessionTimeout = 120
        XCTAssertEqual(config.sessionTimeout, 120)
    }

    func testAppStartConfigDefaultsAndClamping() {
        let defaultConfig = ARTrackerConfig()
        XCTAssertTrue(defaultConfig.enableAppStartTracking)
        XCTAssertFalse(defaultConfig.enableStartupProfiling)
        XCTAssertEqual(defaultConfig.startupProfileSampleRate, 0.1)

        let customConfig = ARTrackerConfig(
            enableAppStartTracking: false,
            enableStartupProfiling: true,
            startupProfileSampleRate: 0.5
        )
        XCTAssertFalse(customConfig.enableAppStartTracking)
        XCTAssertTrue(customConfig.enableStartupProfiling)
        XCTAssertEqual(customConfig.startupProfileSampleRate, 0.5)

        let tooLow = ARTrackerConfig(startupProfileSampleRate: -0.5)
        XCTAssertEqual(tooLow.startupProfileSampleRate, 0.0)

        let tooHigh = ARTrackerConfig(startupProfileSampleRate: 2.5)
        XCTAssertEqual(tooHigh.startupProfileSampleRate, 1.0)
    }
}

