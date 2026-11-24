import XCTest
@testable import ARTracker

final class ErrorTriggerPolicyTests: XCTestCase {
    func testTableRateLimitThreePerSessionAndSixtySecondGap() {
        let policy = ErrorTriggerPolicy(maxPerSession: 3, minGapMs: 60_000)

        // 1. Session s1, t = 0 -> admitted
        XCTAssertTrue(policy.admit(sessionId: "s1", nowMs: 0))

        // 2. Session s1, t = 1_000 -> rejected (gap < 60s)
        XCTAssertFalse(policy.admit(sessionId: "s1", nowMs: 1_000))

        // 3. Session s1, t = 60_000 -> admitted (2nd trigger)
        XCTAssertTrue(policy.admit(sessionId: "s1", nowMs: 60_000))

        // 4. Session s1, t = 120_000 -> admitted (3rd trigger)
        XCTAssertTrue(policy.admit(sessionId: "s1", nowMs: 120_000))

        // 5. Session s1, t = 999_000 -> rejected (exceeded 3 per session)
        XCTAssertFalse(policy.admit(sessionId: "s1", nowMs: 999_000))

        // 6. Session s2, t = 999_500 -> admitted (new session resets counter & gap)
        XCTAssertTrue(policy.admit(sessionId: "s2", nowMs: 999_500))
    }
}
