import XCTest
@testable import ARTracker
#if canImport(UIKit)
import UIKit
#endif

final class TouchTrackerTests: XCTestCase {
    #if canImport(UIKit)
    @MainActor
    func testBeganFiresUserInputOnce() {
        let tracker = TouchTracker.shared
        var userInputCount = 0
        tracker.startActivityTracking {
            userInputCount += 1
        }

        var gestureEvents: [String] = []
        tracker.setGestureHandler { _, kind, _ in
            gestureEvents.append(kind)
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let point = CGPoint(x: 100, y: 200)

        tracker.simulateTouchForTesting(phase: .began, point: point, window: window, now: 100.0)
        tracker.simulateTouchForTesting(phase: .moved, point: CGPoint(x: 120, y: 220), window: window, now: 100.05)
        tracker.simulateTouchForTesting(phase: .ended, point: CGPoint(x: 120, y: 220), window: window, now: 100.10)

        XCTAssertEqual(userInputCount, 1)
        XCTAssertEqual(gestureEvents, ["down", "move", "up"])
    }

    @MainActor
    func testTouchExtendsSessionWithoutReplay() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        let clock = FakeClock()
        let sessionMgr = SessionManager(uptime: { clock.now })
        let tracker = TouchTracker.shared

        // Replay is off: gesture handler is nil
        tracker.setGestureHandler(nil)
        tracker.startActivityTracking {
            sessionMgr.recordUserActivity()
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let initialSessionId = sessionMgr.sessionId

        // Touch at 29 min
        clock.now = 29 * 60
        tracker.simulateTouchForTesting(phase: .began, point: CGPoint(x: 50, y: 50), window: window)
        XCTAssertEqual(sessionMgr.sessionId, initialSessionId)
        XCTAssertFalse(sessionMgr.isExpired)

        // Touch at 31 min since start (which is only 2 min since last touch at 29 min)
        clock.now = 31 * 60
        tracker.simulateTouchForTesting(phase: .began, point: CGPoint(x: 60, y: 60), window: window)
        XCTAssertEqual(sessionMgr.sessionId, initialSessionId)
        XCTAssertFalse(sessionMgr.isExpired)
    }
    #endif
}
