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
        XCTAssertNotEqual(manager.sessionId, initialId)
    }
}

