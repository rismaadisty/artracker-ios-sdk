import XCTest
@testable import ARTracker

final class CaptureActivityGovernorTests: XCTestCase {

    func testStartsActive() {
        let governor = CaptureActivityGovernor(activeFps: 2.0)
        governor.onStart(nowMs: 1000)
        XCTAssertEqual(governor.state, .active)
        XCTAssertEqual(governor.periodicFps(), 2.0)
        XCTAssertTrue(governor.keyframeAllowed)
        XCTAssertEqual(governor.nextTransitionAtMs(), 1000 + 30_000)
    }

    func testIdleAfter30s() {
        let governor = CaptureActivityGovernor(activeFps: 2.0)
        governor.onStart(nowMs: 1000)

        // At 29.9s -> still active
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 29_999), .active)

        // At 30s -> idle
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 30_000), .idle)
        XCTAssertEqual(governor.state, .idle)
        XCTAssertEqual(governor.periodicFps(), 0.2)
        XCTAssertFalse(governor.keyframeAllowed)
        XCTAssertEqual(governor.nextTransitionAtMs(), 1000 + 180_000)
    }

    func testDormantAfter180s() {
        let governor = CaptureActivityGovernor(activeFps: 2.0)
        governor.onStart(nowMs: 1000)

        // At 179.9s -> idle
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 179_999), .idle)

        // At 180s -> dormant
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 180_000), .dormant)
        XCTAssertEqual(governor.state, .dormant)
        XCTAssertNil(governor.periodicFps())
        XCTAssertFalse(governor.keyframeAllowed)
        XCTAssertNil(governor.nextTransitionAtMs())
    }

    func testInputWakes() {
        let governor = CaptureActivityGovernor(activeFps: 2.0)
        governor.onStart(nowMs: 1000)

        // Go to dormant
        governor.evaluate(nowMs: 1000 + 200_000)
        XCTAssertEqual(governor.state, .dormant)

        // Input wakes
        let woke = governor.onUserInput(nowMs: 1000 + 201_000)
        XCTAssertTrue(woke)
        XCTAssertEqual(governor.state, .active)
        XCTAssertEqual(governor.periodicFps(), 2.0)
        XCTAssertEqual(governor.nextTransitionAtMs(), 202_000 + 30_000)

        // Input while already active returns false
        let wokeAgain = governor.onUserInput(nowMs: 202_500)
        XCTAssertFalse(wokeAgain)
        XCTAssertEqual(governor.state, .active)
    }

    func testTriggerDebounce() {
        let governor = CaptureActivityGovernor(activeFps: 2.0)
        governor.onStart(nowMs: 1000)

        // In active state
        XCTAssertEqual(governor.admitTrigger(.screen, nowMs: 2000), 300)
        XCTAssertEqual(governor.admitTrigger(.window, nowMs: 2000), 300)
        XCTAssertEqual(governor.admitTrigger(.error, nowMs: 2000), 300)
        XCTAssertEqual(governor.admitTrigger(.keyboard, nowMs: 2000), 300)
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: 2000), 500)
        XCTAssertEqual(governor.admitTrigger(.manual, nowMs: 2000), 0)

        // Transition to dormant, triggers should never change state
        governor.evaluate(nowMs: 1000 + 190_000)
        XCTAssertEqual(governor.state, .dormant)

        XCTAssertEqual(governor.admitTrigger(.screen, nowMs: 200_000), 300)
        XCTAssertEqual(governor.state, .dormant)

        XCTAssertEqual(governor.admitTrigger(.manual, nowMs: 201_000), 0)
        XCTAssertEqual(governor.state, .dormant)
    }

    func testNetworkRateLimit() {
        let governor = CaptureActivityGovernor(activeFps: 2.0)
        governor.onStart(nowMs: 0)

        // ACTIVE: unlimited
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: 100), 500)
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: 200), 500)
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: 300), 500)

        // Transition to IDLE at 30_000
        governor.evaluate(nowMs: 30_000)
        XCTAssertEqual(governor.state, .idle)

        // IDLE: 1 per 5 000 ms
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: 30_000), 500)
        XCTAssertNil(governor.admitTrigger(.network, nowMs: 31_000))
        XCTAssertNil(governor.admitTrigger(.network, nowMs: 34_999))
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: 35_000), 500)

        // Transition to DORMANT at 180_000
        governor.evaluate(nowMs: 180_000)
        XCTAssertEqual(governor.state, .dormant)

        // DORMANT: 1 per 10 000 ms (+0, +3000, +6000, +9000, +10000 -> admitted, nil, nil, nil, admitted)
        let baseDormant: Int64 = 180_000
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: baseDormant + 0), 500)
        XCTAssertNil(governor.admitTrigger(.network, nowMs: baseDormant + 3_000))
        XCTAssertNil(governor.admitTrigger(.network, nowMs: baseDormant + 6_000))
        XCTAssertNil(governor.admitTrigger(.network, nowMs: baseDormant + 9_000))
        XCTAssertEqual(governor.admitTrigger(.network, nowMs: baseDormant + 10_000), 500)
    }

    func testCustomThresholds() {
        let governor = CaptureActivityGovernor(activeFps: 3.0, idleAfterMs: 5_000, dormantAfterMs: 6_000)
        governor.onStart(nowMs: 1000)

        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 4_999), .active)
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 5_000), .idle)
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 5_999), .idle)
        XCTAssertEqual(governor.evaluate(nowMs: 1000 + 6_000), .dormant)
    }
}
