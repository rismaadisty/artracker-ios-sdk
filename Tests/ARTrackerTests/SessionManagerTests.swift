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
        let suiteName = "test.session.user.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = SessionManager(userDefaults: defaults)
        XCTAssertNil(manager.userId)

        manager.userId = "user_alice_42"
        XCTAssertEqual(manager.userId, "user_alice_42")
        XCTAssertEqual(defaults.string(forKey: "artracker.user_id"), "user_alice_42")

        // Restoring in new manager loads persisted user
        let manager2 = SessionManager(userDefaults: defaults)
        XCTAssertEqual(manager2.userId, "user_alice_42")

        manager.userId = nil
        XCTAssertNil(manager.userId)
        XCTAssertNil(defaults.string(forKey: "artracker.user_id"))
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

    func testRelaunchWithin30MinKeepsSession() {
        let suiteName = "test.session.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 1_000_000
        }
        let clock = FakeClock()

        let manager1 = SessionManager(clock: { clock.now }, userDefaults: defaults)
        let initialId = manager1.sessionId
        manager1.recordUserActivity()
        manager1.persistSession(forced: true)

        // Relaunch 15 minutes later (< 30 min idle timeout)
        clock.now += 15 * 60
        let manager2 = SessionManager(clock: { clock.now }, userDefaults: defaults)

        XCTAssertEqual(manager2.sessionId, initialId)
        XCTAssertFalse(manager2.isExpired)
    }

    func testRelaunchAfter31MinEndsStoredSession() {
        let suiteName = "test.session.expired.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 1_000_000
        }
        final class ListenerSpy: SessionLifecycleListener, @unchecked Sendable {
            var endedEvents: [(id: String, durationMs: Double)] = []
            func sessionDidStart(id: String) {}
            func sessionDidEnd(id: String, durationMs: Double) { endedEvents.append((id, durationMs)) }
        }

        let clock = FakeClock()
        let manager1 = SessionManager(clock: { clock.now }, userDefaults: defaults)
        let initialId = manager1.sessionId
        clock.now += 5 * 60 // activity at 5 min
        manager1.recordUserActivity()
        manager1.persistSession(forced: true)

        // Relaunch 31 minutes after last activity (36 min total)
        clock.now += 31 * 60
        let spy = ListenerSpy()
        let manager2 = SessionManager(clock: { clock.now }, userDefaults: defaults)
        manager2.listener = spy

        XCTAssertNotEqual(manager2.sessionId, initialId)
        XCTAssertEqual(spy.endedEvents.count, 1)
        XCTAssertEqual(spy.endedEvents.first?.id, initialId)
        // Duration: last activity (5 min) - started (0 min) = 300 s = 300 000 ms
        XCTAssertEqual(spy.endedEvents.first?.durationMs, 300_000)
    }

    func testClockJumpBackwardsDoesNotExtend() {
        let suiteName = "test.session.clockjump.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 1_000_000
        }
        let clock = FakeClock()
        let manager = SessionManager(clock: { clock.now }, userDefaults: defaults)
        let initialId = manager.sessionId

        // User activity at 1_000_000
        manager.recordUserActivity()

        // Clock jumps backwards by 500 seconds
        clock.now -= 500
        manager.recordUserActivity()

        // 31 minutes later from the new time
        clock.now += 31 * 60
        XCTAssertTrue(manager.isExpired)

        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, initialId)
    }

    func testDefaultIdleTimeoutIsThirtyMinutes() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        XCTAssertEqual(manager.idleTimeout, 1800)
        let id = manager.sessionId
        clock.now = 1800
        manager.recordUserActivity()
        XCTAssertEqual(manager.sessionId, id)      // tepat di batas timeout: sesi dipertahankan, aktivitas di-refresh
        clock.now = 1800 + 1801
        XCTAssertTrue(manager.isExpired)
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, id)
    }

    func testCustomIdleTimeoutRotatesAfterItElapses() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now }, idleTimeout: 60)
        let id = manager.sessionId
        clock.now = 59
        manager.recordUserActivity()
        XCTAssertEqual(manager.sessionId, id)
        clock.now = 59 + 61
        XCTAssertTrue(manager.isExpired)
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, id)
    }

    func testConfigureChangesTimeoutForNextCheck() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now })
        let id = manager.sessionId
        manager.configure(idleTimeout: 60)
        XCTAssertEqual(manager.idleTimeout, 60)
        clock.now = 61
        XCTAssertTrue(manager.isExpired)
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, id)
    }

    func testConfigureClampsBelowMinimum() {
        let manager = SessionManager(uptime: { 0 })
        manager.configure(idleTimeout: 0)
        XCTAssertEqual(manager.idleTimeout, 1)
        manager.configure(idleTimeout: .infinity)
        XCTAssertEqual(manager.idleTimeout, 1800)
    }

    func testPeekUsesCustomTimeoutWithoutRotating() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now }, idleTimeout: 60)
        let id = manager.sessionId
        clock.now = 61
        XCTAssertNil(manager.peekSessionId())
        XCTAssertNil(manager.peekSessionId())       // peek tidak pernah memutar atau me-refresh sesi
        XCTAssertEqual(manager.sessionId, id)       // pure read tetap mengembalikan id sebelum ada aktivitas
        manager.recordUserActivity()
        XCTAssertNotEqual(manager.sessionId, id)
    }

    func testForegroundAfterTimeoutStartsNewSession() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now }, idleTimeout: 60)
        let id = manager.sessionId
        clock.now = 61
        manager.onForeground()
        let afterForeground = manager.peekSessionId()
        XCTAssertNotNil(afterForeground)
        XCTAssertNotEqual(afterForeground, id)
    }

    func testForegroundWithinTimeoutKeepsSessionAndRefreshesActivity() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now }, idleTimeout: 60)
        let id = manager.sessionId
        clock.now = 50
        manager.onForeground()
        clock.now = 100                              // 50 dtk setelah foreground, 100 dtk sejak start
        XCTAssertEqual(manager.peekSessionId(), id)
    }

    func testForegroundAtExactTimeoutKeepsSession() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now }, idleTimeout: 60)
        let id = manager.sessionId
        clock.now = 60
        manager.onForeground()
        XCTAssertEqual(manager.peekSessionId(), id)
    }

    func testRotateStillWorksWithCustomTimeout() {
        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = FakeClock()
        let manager = SessionManager(uptime: { clock.now }, idleTimeout: 60)
        let id = manager.sessionId
        let rotated = manager.rotateSession()
        XCTAssertNotEqual(rotated, id)
        clock.now = 30
        XCTAssertEqual(manager.sessionId, rotated)
    }

    func testConfigureReevaluatesRestoredSessionAgainstNewTimeout() {
        let suiteName = "test.session.reconfig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        final class FakeClock: @unchecked Sendable { var now: TimeInterval = 1_000_000 }
        final class ListenerSpy: SessionLifecycleListener, @unchecked Sendable {
            var endedEvents: [(id: String, durationMs: Double)] = []
            var startedIds: [String] = []
            func sessionDidStart(id: String) { startedIds.append(id) }
            func sessionDidEnd(id: String, durationMs: Double) { endedEvents.append((id, durationMs)) }
        }

        let clock = FakeClock()
        let manager1 = SessionManager(clock: { clock.now }, userDefaults: defaults)
        let initialId = manager1.sessionId
        clock.now += 10
        manager1.recordUserActivity()
        manager1.persistSession(forced: true)

        // Relaunch 120 detik kemudian (< default 1800, tetapi > custom timeout 60)
        clock.now += 120
        let manager2 = SessionManager(clock: { clock.now }, userDefaults: defaults)
        // Sebelum configure(60), gdyby memakai 1800 sesi masih dianggap valid;
        // Begitu configure(idleTimeout: 60) dipanggil, sesi lama harus dievaluasi ulang dan dirotasi!
        manager2.configure(idleTimeout: 60)
        let spy = ListenerSpy()
        manager2.listener = spy

        XCTAssertNotEqual(manager2.sessionId, initialId)
        XCTAssertEqual(spy.endedEvents.count, 1)
        XCTAssertEqual(spy.endedEvents.first?.id, initialId)
        XCTAssertEqual(spy.endedEvents.first?.durationMs, 10_000)
    }

    func testApplySessionConfigPassesTimeoutToManager() {
        let manager = SessionManager(uptime: { 0 })
        ARTracker.applySessionConfig(ARTrackerConfig(sessionTimeout: 60), to: manager)
        XCTAssertEqual(manager.idleTimeout, 60)
    }

    func testApplySessionConfigWithDefaultConfigKeepsThirtyMinutes() {
        let manager = SessionManager(uptime: { 0 }, idleTimeout: 60)
        ARTracker.applySessionConfig(ARTrackerConfig(), to: manager)
        XCTAssertEqual(manager.idleTimeout, 1800)
    }
}

