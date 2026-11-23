import XCTest
@testable import ARTracker

final class AppStartTrackerTests: XCTestCase {
    private func ms(_ milliseconds: UInt64) -> UInt64 {
        milliseconds * 1_000_000
    }

    func testColdHasFivePhasesSummingToDuration() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(120),
            newId: { "test-id-1" },
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        tracker.configured(at: ms(300), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(900))
        tracker.didBecomeActive(at: ms(1000))
        XCTAssertTrue(tracker.awaitingFirstFrame)
        tracker.firstFrame(at: ms(1180), screen: "HomeViewController")
        XCTAssertFalse(tracker.awaitingFirstFrame)

        guard let r = reported else {
            XCTFail("Expected start record")
            return
        }
        XCTAssertEqual(r.type, .cold)
        XCTAssertEqual(r.durationMs, 1180)
        XCTAssertEqual(r.firstScreen, "HomeViewController")
        XCTAssertTrue(r.profiled)
        XCTAssertEqual(r.phases.map(\.name), ["pre_main", "pre_init", "did_finish_launching", "scene_activation", "first_draw"])
        XCTAssertEqual(r.phases.map(\.ms), [120, 180, 600, 100, 180])
        XCTAssertEqual(r.phases.map(\.ms).reduce(0, +), r.durationMs)
        XCTAssertFalse(abandoned)
    }

    func testConfigureBeforeDidFinishLaunchingKeepsAllPhases() {
        var reported: AppStartRecord?
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: false)
        tracker.didFinishLaunching(at: ms(700))
        tracker.didBecomeActive(at: ms(800))
        tracker.firstFrame(at: ms(950), screen: nil)

        guard let r = reported else {
            XCTFail("Expected start record")
            return
        }
        XCTAssertEqual(r.type, .cold)
        XCTAssertEqual(r.durationMs, 950)
        XCTAssertEqual(r.phases.map(\.name), ["pre_main", "pre_init", "did_finish_launching", "scene_activation", "first_draw"])
        XCTAssertEqual(r.phases.map(\.ms), [100, 100, 500, 100, 150])
        XCTAssertEqual(r.phases.map(\.ms).reduce(0, +), r.durationMs)
    }

    func testMissingDidFinishMergesIntoSceneActivation() {
        var reported: AppStartRecord?
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: false)
        // didFinishLaunching is not called
        tracker.didBecomeActive(at: ms(600))
        tracker.firstFrame(at: ms(800), screen: nil)

        guard let r = reported else {
            XCTFail("Expected start record")
            return
        }
        XCTAssertEqual(r.type, .cold)
        XCTAssertEqual(r.durationMs, 800)
        XCTAssertEqual(r.phases.map(\.name), ["pre_main", "pre_init", "scene_activation", "first_draw"])
        XCTAssertEqual(r.phases.map(\.ms), [100, 100, 400, 200])
        XCTAssertEqual(r.phases.map(\.ms).reduce(0, +), r.durationMs)
    }

    func testNoProcessStartMeansNoColdReport() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: nil,
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(400))
        tracker.didBecomeActive(at: ms(500))
        tracker.firstFrame(at: ms(600), screen: nil)

        XCTAssertNil(reported)
        XCTAssertTrue(abandoned)
    }

    func testLateConfigureDropsCold() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        let lateNs = AppStartTracker.lateInitNs + ms(1)
        tracker.configured(at: lateNs, context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: lateNs + ms(100))
        tracker.didBecomeActive(at: lateNs + ms(200))
        tracker.firstFrame(at: lateNs + ms(300), screen: nil)

        XCTAssertNil(reported)
        XCTAssertTrue(abandoned)
    }

    func testConfigureWhenAlreadyActiveReportsNothing() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        tracker.configured(at: ms(500), context: .activeAlready, profiled: true)
        tracker.firstFrame(at: ms(600), screen: nil)

        XCTAssertNil(reported)
        XCTAssertTrue(abandoned)
    }

    func testBackgroundBeforeFirstFrameDropsAndAbandons() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(400))
        tracker.didEnterBackground(at: ms(500))
        tracker.didBecomeActive(at: ms(600))
        tracker.firstFrame(at: ms(700), screen: nil)

        XCTAssertNil(reported)
        XCTAssertTrue(abandoned)
    }

    func testColdOver60sDropped() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(400))
        tracker.didBecomeActive(at: ms(500))
        tracker.firstFrame(at: ms(60_001), screen: nil)

        XCTAssertNil(reported)
        XCTAssertTrue(abandoned)
    }

    func testPrewarmedIsWarmFromConfigure() {
        var reported: AppStartRecord?
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(5000), context: .prewarmed, profiled: false)
        tracker.didFinishLaunching(at: ms(5400))
        tracker.didBecomeActive(at: ms(5500))
        tracker.firstFrame(at: ms(5600), screen: nil)

        guard let r = reported else {
            XCTFail("Expected start record")
            return
        }
        XCTAssertEqual(r.type, .warm)
        XCTAssertEqual(r.durationMs, 600)
        XCTAssertEqual(r.phases.map(\.name), ["did_finish_launching", "scene_activation", "first_draw"])
        XCTAssertEqual(r.phases.map(\.ms), [400, 100, 100])
        XCTAssertEqual(r.phases.map(\.ms).reduce(0, +), r.durationMs)
    }

    func testBackgroundLaunchThenForegroundIsWarm() {
        var reported: AppStartRecord?
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(0), context: .background, profiled: false)
        tracker.willEnterForeground(at: ms(300_000))
        tracker.didBecomeActive(at: ms(300_200))
        tracker.firstFrame(at: ms(300_350), screen: nil)

        guard let r = reported else {
            XCTFail("Expected start record")
            return
        }
        XCTAssertEqual(r.type, .warm)
        XCTAssertEqual(r.durationMs, 350)
        XCTAssertEqual(r.phases.map(\.name), ["foreground_transition", "first_draw"])
        XCTAssertEqual(r.phases.map(\.ms), [200, 150])
        XCTAssertEqual(r.phases.map(\.ms).reduce(0, +), r.durationMs)
    }

    func testHotAfterBackground() {
        var reports: [AppStartRecord] = []
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reports.append($0) },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: false)
        tracker.didFinishLaunching(at: ms(400))
        tracker.didBecomeActive(at: ms(500))
        tracker.firstFrame(at: ms(600), screen: nil)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].type, .cold)

        tracker.didEnterBackground(at: ms(10_000))
        tracker.willEnterForeground(at: ms(50_000))
        tracker.didBecomeActive(at: ms(50_100))
        tracker.firstFrame(at: ms(50_160), screen: nil)

        XCTAssertEqual(reports.count, 2)
        let hot = reports[1]
        XCTAssertEqual(hot.type, .hot)
        XCTAssertEqual(hot.durationMs, 160)
        XCTAssertEqual(hot.phases.map(\.name), ["foreground_transition", "first_draw"])
        XCTAssertEqual(hot.phases.map(\.ms), [100, 60])
        XCTAssertEqual(hot.phases.map(\.ms).reduce(0, +), hot.durationMs)
    }

    func testWarmOrHotOver10sDropped() {
        var reported: AppStartRecord?
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(0), context: .background, profiled: false)
        tracker.willEnterForeground(at: ms(10_000))
        tracker.didBecomeActive(at: ms(10_100))
        tracker.firstFrame(at: ms(20_001), screen: nil) // 10,001 ms duration

        XCTAssertNil(reported)
    }

    func testFirstFrameWithoutPendingStartIgnored() {
        var reports: [AppStartRecord] = []
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reports.append($0) },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: false)
        tracker.didFinishLaunching(at: ms(300))
        tracker.didBecomeActive(at: ms(400))
        tracker.firstFrame(at: ms(500), screen: nil)
        XCTAssertEqual(reports.count, 1)

        tracker.firstFrame(at: ms(516), screen: nil)
        tracker.firstFrame(at: ms(533), screen: nil)
        XCTAssertEqual(reports.count, 1)
    }

    func testEachStartHasUniqueId() {
        var ids: [String] = []
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { ids.append($0.startId) },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: false)
        tracker.didFinishLaunching(at: ms(300))
        tracker.didBecomeActive(at: ms(400))
        tracker.firstFrame(at: ms(500), screen: nil)

        tracker.didEnterBackground(at: ms(1000))
        tracker.willEnterForeground(at: ms(2000))
        tracker.didBecomeActive(at: ms(2100))
        tracker.firstFrame(at: ms(2200), screen: nil)

        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testProfiledFlagOnlyOnCold() {
        var reports: [AppStartRecord] = []
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reports.append($0) },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(300))
        tracker.didBecomeActive(at: ms(400))
        tracker.firstFrame(at: ms(500), screen: nil)

        tracker.didEnterBackground(at: ms(1000))
        tracker.willEnterForeground(at: ms(2000))
        tracker.didBecomeActive(at: ms(2100))
        tracker.firstFrame(at: ms(2200), screen: nil)

        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports[0].profiled)
        XCTAssertFalse(reports[1].profiled)
    }

    func testWillEnterForegroundDuringColdLaunchDoesNotDowngradeColdToWarm() {
        var reported: AppStartRecord?
        var abandoned = 0
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned += 1 }
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(300))
        // iOS 13+ UIScene / SwiftUI apps fire willEnterForegroundNotification during cold launch:
        tracker.willEnterForeground(at: ms(350))
        tracker.didBecomeActive(at: ms(400))
        tracker.firstFrame(at: ms(500), screen: "Home")

        XCTAssertEqual(abandoned, 0)
        XCTAssertEqual(reported?.type, .cold)
        XCTAssertEqual(reported?.profiled, true)
        XCTAssertEqual(reported?.durationMs, 500)
    }

    func testDelayedWillEnterForegroundAfterSilentBackgroundLaunchDowngradesToWarm() {
        var reported: AppStartRecord?
        var abandoned = 0
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(100),
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned += 1 }
        )

        tracker.configured(at: ms(200), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(300))
        // App stayed in background (no didBecomeActive) for > 3s, confirmed background launch:
        tracker.confirmBackgroundLaunchIfNotActive()
        XCTAssertEqual(abandoned, 1)

        // Later user opened it at 15s:
        tracker.willEnterForeground(at: ms(15_000))
        tracker.didBecomeActive(at: ms(15_150))
        tracker.firstFrame(at: ms(15_280), screen: "Home")

        XCTAssertEqual(reported?.type, .warm)
        XCTAssertEqual(reported?.profiled, false)
        XCTAssertEqual(reported?.durationMs, 280)
    }

    func testDebuggerAttachedStripsLLDBPreMainPauseFromColdDurationAndAnchor() {
        var reported: AppStartRecord?
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(14_000), // 14s LLDB pause in dyld
            isDebuggerAttached: true,
            onReport: { reported = $0 },
            onColdAbandoned: {}
        )

        tracker.configured(at: ms(14_100), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(14_200))
        tracker.didBecomeActive(at: ms(14_300))
        tracker.firstFrame(at: ms(14_450), screen: "Home")

        guard let r = reported else {
            XCTFail("Expected reported cold start record")
            return
        }
        XCTAssertEqual(r.type, .cold)
        XCTAssertTrue(r.profiled)
        // Duration should be 450ms (from preMainEnd at 14_000 to firstFrame at 14_450), NOT 14_450ms
        XCTAssertEqual(r.durationMs, 450)
        XCTAssertEqual(r.anchorNs, ms(14_000))

        let totalPhasesMs = r.phases.reduce(0) { $0 + $1.ms }
        XCTAssertEqual(totalPhasesMs, 450)
        XCTAssertFalse(r.phases.contains { $0.name == "pre_main" })
    }

    func testProductionDoesNotRebaseWhenDebuggerNotAttached() {
        var reported: AppStartRecord?
        var abandoned = false
        let tracker = AppStartTracker(
            processStartNs: ms(0),
            preMainEndNs: ms(14_000),
            isDebuggerAttached: false,
            onReport: { reported = $0 },
            onColdAbandoned: { abandoned = true }
        )

        // In production without debugger, 14s exceeds lateInitNs (10s) and gets abandoned
        tracker.configured(at: ms(14_100), context: .foreground, profiled: true)
        tracker.didFinishLaunching(at: ms(14_200))
        tracker.didBecomeActive(at: ms(14_300))
        tracker.firstFrame(at: ms(14_450), screen: "Home")

        XCTAssertNil(reported)
        XCTAssertTrue(abandoned)
    }
}
