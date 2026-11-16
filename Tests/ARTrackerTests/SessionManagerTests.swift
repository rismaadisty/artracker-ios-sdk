import XCTest
@testable import ARTracker

final class SessionManagerTests: XCTestCase {
    func testSessionIdFormatMatchesContract() {
        let sessionId = SessionManager.shared.sessionId
        XCTAssertTrue(sessionId.hasPrefix("ses_"))
        XCTAssertEqual(sessionId.count, 4 + 24) // "ses_" + 24 hex characters

        // Hex regex validation
        let hexPart = String(sessionId.dropFirst(4))
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(CharacterSet(charactersIn: hexPart).isSubset(of: hexCharacterSet))
    }

    func testUserIdentityTracking() {
        let manager = SessionManager()
        XCTAssertNil(manager.userId)

        manager.userId = "user_alice_42"
        XCTAssertEqual(manager.userId, "user_alice_42")

        manager.userId = nil
        XCTAssertNil(manager.userId)
    }

    func testManualSessionRotation() {
        let manager = SessionManager()
        let first = manager.sessionId
        let rotated = manager.rotateSession()

        XCTAssertNotEqual(first, rotated)
        XCTAssertEqual(manager.sessionId, rotated)
    }

    func testPeekDoesNotRefreshActivity() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })

        let initialId = manager.sessionId

        clock.now = 1000
        XCTAssertEqual(manager.peekSessionId(), initialId)

        clock.now = 1900
        XCTAssertNil(manager.peekSessionId())
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, initialId)
    }

    func testRepeatedPeekStillAllowsRotationAtIdleTimeout() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })

        let initialId = manager.sessionId

        clock.now = 1000
        XCTAssertEqual(manager.peekSessionId(), initialId)

        clock.now = 1500
        XCTAssertEqual(manager.peekSessionId(), initialId)

        clock.now = 1801
        XCTAssertNil(manager.peekSessionId())
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, initialId)
    }

    func testReadsDoNotExtendSession() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        final class ListenerSpy: SessionLifecycleListener, @unchecked Sendable {
            var startedIds: [String] = []
            var endedEvents: [(id: String, durationMs: Double)] = []
            func sessionDidStart(id: String) { startedIds.append(id) }
            func sessionDidEnd(id: String, durationMs: Double) { endedEvents.append((id, durationMs)) }
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        let spy = ListenerSpy()
        manager.listener = spy

        let initialId = manager.sessionId

        // Read every 60s for 31 minutes
        for _ in 1...31 {
            clock.now += 60
            XCTAssertEqual(manager.sessionId, initialId)
        }
        XCTAssertTrue(manager.isExpired)
        XCTAssertEqual(spy.endedEvents.count, 0)

        // User activity after expiry rotates session and emits end event with duration 0
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, initialId)
        XCTAssertFalse(manager.isExpired)
        XCTAssertEqual(spy.endedEvents.count, 1)
        XCTAssertEqual(spy.endedEvents.first?.id, initialId)
        XCTAssertEqual(spy.endedEvents.first?.durationMs, 0)
        XCTAssertEqual(spy.startedIds.last, manager.sessionId)
    }

    func testInputWithinTimeoutKeepsSession() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        let initialId = manager.sessionId

        clock.now = 29 * 60 // 29 minutes
        manager.recordUserActivity()
        XCTAssertEqual(manager.sessionId, initialId)
        XCTAssertFalse(manager.isExpired)
    }

    func testInputAfterTimeoutRotatesWithDurationToLastInput() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        final class ListenerSpy: SessionLifecycleListener, @unchecked Sendable {
            var endedEvents: [(id: String, durationMs: Double)] = []
            func sessionDidStart(id: String) {}
            func sessionDidEnd(id: String, durationMs: Double) { endedEvents.append((id, durationMs)) }
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        let spy = ListenerSpy()
        manager.listener = spy
        let initialId = manager.sessionId

        clock.now = 5 * 60 // 5 minutes
        manager.recordUserActivity()

        clock.now = 36 * 60 // 36 minutes (31 mins since last activity, timeout is 30 mins)
        manager.recordUserActivity()

        XCTAssertNotEqual(manager.sessionId, initialId)
        XCTAssertEqual(spy.endedEvents.count, 1)
        XCTAssertEqual(spy.endedEvents.first?.id, initialId)
        // Duration: last activity (5 min) - started (0 min) = 300 s = 300 000 ms
        XCTAssertEqual(spy.endedEvents.first?.durationMs, 300_000)
    }

    func testPeriodicReadsNeverRotate() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        final class ListenerSpy: SessionLifecycleListener, @unchecked Sendable {
            var starts = 0
            var ends = 0
            func sessionDidStart(id: String) { starts += 1 }
            func sessionDidEnd(id: String, durationMs: Double) { ends += 1 }
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        let spy = ListenerSpy()
        manager.listener = spy
        let initialId = manager.sessionId

        // 120 reads over 26 hours without user input
        for _ in 1...120 {
            clock.now += 780 // ~13 mins step
            XCTAssertEqual(manager.sessionId, initialId)
        }
        XCTAssertTrue(manager.isExpired)
        XCTAssertEqual(spy.ends, 0)
        XCTAssertEqual(spy.starts, 0)
    }

    func testHardCapRotatesAt24h() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 0
        }
        final class ListenerSpy: SessionLifecycleListener, @unchecked Sendable {
            var endedEvents: [(id: String, durationMs: Double)] = []
            func sessionDidStart(id: String) {}
            func sessionDidEnd(id: String, durationMs: Double) { endedEvents.append((id, durationMs)) }
        }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        let spy = ListenerSpy()
        manager.listener = spy
        let initialId = manager.sessionId

        // Active every 20 minutes for 24 hours
        for _ in 1...71 {
            clock.now += 20 * 60
            manager.recordUserActivity()
            XCTAssertEqual(manager.sessionId, initialId)
        }

        // At 24h (86400s), last activity was at 85200s
        clock.now = 86_400
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, initialId)
        XCTAssertEqual(spy.endedEvents.count, 1)
        XCTAssertEqual(spy.endedEvents.first?.durationMs, 85_200 * 1000)
    }
}

