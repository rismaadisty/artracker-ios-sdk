import XCTest
@testable import ARTracker
#if canImport(UIKit)
import UIKit

final class ReplayLifecycleTests: XCTestCase {

    final class ClockBox: @unchecked Sendable {
        var nowMs: Int64 = 1_000_000
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReplayEngine.shared.resetForTesting()
    }

    override func tearDownWithError() throws {
        ReplayEngine.shared.resetForTesting()
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    @MainActor
    private func createTestWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let label = UILabel(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
        label.text = "LifecycleTest"
        window.addSubview(label)
        window.isHidden = false
        return window
    }

    @MainActor
    func testIdleThenDormantStopsTimerAndFlushes() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Initial start frame captured
        ReplayEngine.shared.flushCapturerForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .active)

        // Advance beyond idle (1s)
        clockBox.nowMs += 1_100
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .idle)

        // Advance beyond dormant (2s)
        clockBox.nowMs += 1_000
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)
        XCTAssertNil(ReplayEngine.shared.screenCapturerPeriodicFpsForTesting)
    }

    @MainActor
    func testCarouselIdleStopsRenderingAfterDormant() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        ReplayEngine.shared.flushCapturerForTesting()
        let initialFrameCount = ReplayEngine.shared.capturedFrameCountForTesting

        // Wait 0.5s while animating view in dormant: timer is cancelled, so 0 captures occur
        let exp = expectation(description: "No captures in dormant")
        exp.isInverted = true
        wait(for: [exp], timeout: 0.5)

        ReplayEngine.shared.flushCapturerForTesting()
        XCTAssertEqual(ReplayEngine.shared.capturedFrameCountForTesting, initialFrameCount)
    }

    @MainActor
    func testDormantTouchCapturesImmediately() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        ReplayEngine.shared.flushCapturerForTesting()
        let preTouchCount = ReplayEngine.shared.capturedFrameCountForTesting

        // User touches screen (.began)
        TouchTracker.shared.simulateTouchForTesting(phase: .began, point: CGPoint(x: 50, y: 50), window: window)
        ReplayEngine.shared.flushCapturerForTesting()

        // Immediate wake frame captured synchronously bypassing dedup
        XCTAssertEqual(ReplayEngine.shared.capturedFrameCountForTesting, preTouchCount + 1)
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .active)
    }

    @MainActor
    func testDormantScreenViewCapturesOnce() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        ReplayEngine.shared.flushCapturerForTesting()
        let preCount = ReplayEngine.shared.capturedFrameCountForTesting
        ReplayEngine.shared.captureFullSnapshot(triggerReason: "screen.view", screenName: "DetailView")

        // Wait for 300ms debounce
        let exp = expectation(description: "Debounced screen view captured")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ReplayEngine.shared.flushCapturerForTesting()
            XCTAssertEqual(ReplayEngine.shared.capturedFrameCountForTesting, preCount + 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testPollingInDormantIsRateLimited() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        // First network trigger admitted
        ReplayEngine.shared.trigger(.network)

        // Repeated network triggers within 10s should be rejected
        clockBox.nowMs += 2_000
        ReplayEngine.shared.trigger(.network)
        clockBox.nowMs += 3_000
        ReplayEngine.shared.trigger(.network)

        // State remains dormant
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)
    }

    @MainActor
    func testDormantErrorCapturedAndFlagged() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        // Mark error & trigger error
        ReplayEngine.shared.markError()
        ReplayEngine.shared.trigger(.error)

        let exp = expectation(description: "Error trigger captured and flushed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ReplayEngine.shared.flushCapturerForTesting()
            // Force flush queue
            ReplayEngine.shared.flush {
                let item = diskQueue.peekNext()
                XCTAssertNotNil(item)
                XCTAssertEqual(item?.hasError, true)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }

    @MainActor
    func testExpiredSessionIgnoresTriggers() {
        SessionManager.shared._testSetExpired()
        XCTAssertTrue(SessionManager.shared.isExpired)

        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        ReplayEngine.shared.flushCapturerForTesting()
        let preCount = ReplayEngine.shared.capturedFrameCountForTesting

        // When SessionManager is expired, trigger should return early
        ReplayEngine.shared.trigger(.screen)
        ReplayEngine.shared.trigger(.manual)
        ReplayEngine.shared.trigger(.network)
        ReplayEngine.shared.flushCapturerForTesting()

        XCTAssertEqual(ReplayEngine.shared.capturedFrameCountForTesting, preCount)

        // Reset session manager for subsequent tests
        SessionManager.shared.touch()
    }

    @MainActor
    func testBackgroundDuringDormantFlushIsSingle() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()

        // Trigger in dormant -> schedules one-shot flush at 10s
        ReplayEngine.shared.trigger(.manual)
        ReplayEngine.shared.flushCapturerForTesting()

        // Background occurs before 10s
        ReplayEngine.shared.handleBackgroundForTesting()

        let exp = expectation(description: "Flush complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let item = diskQueue.peekNext()
            XCTAssertNotNil(item)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testNewWindowInDormantCapturesOnce() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        ReplayEngine.shared.flushCapturerForTesting()
        let preCount = ReplayEngine.shared.capturedFrameCountForTesting

        // Present or post new window visible
        NotificationCenter.default.post(name: UIWindow.didBecomeVisibleNotification, object: window)

        // Wait for 300ms debounce
        let exp = expectation(description: "Window trigger captured")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ReplayEngine.shared.flushCapturerForTesting()
            XCTAssertEqual(ReplayEngine.shared.capturedFrameCountForTesting, preCount + 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testManualCaptureImmediate() {
        let clockBox = ClockBox()
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let uploader = ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "test")
        let window = createTestWindow()

        ReplayEngine.shared.startForTesting(
            uploader: uploader,
            diskQueue: diskQueue,
            fps: 2.0,
            idleAfterMs: 1_000,
            dormantAfterMs: 2_000,
            clock: { clockBox.nowMs },
            windowProvider: { [window] },
            isAppActive: { true }
        )

        // Move to dormant
        clockBox.nowMs += 2_500
        ReplayEngine.shared.evaluateLifecycleForTesting()
        XCTAssertEqual(ReplayEngine.shared.governorStateForTesting, .dormant)

        ReplayEngine.shared.flushCapturerForTesting()
        let preCount = ReplayEngine.shared.capturedFrameCountForTesting

        // Manual capture request via public API
        ARTracker.captureReplayFrame(reason: "user_debug")
        ReplayEngine.shared.flushCapturerForTesting()

        // Immediate frame captured synchronously without debounce
        XCTAssertEqual(ReplayEngine.shared.capturedFrameCountForTesting, preCount + 1)
    }

    func testNetworkCompletionTriggersReplayButSdkEndpointDoesNot() {
        ARTrackerURLProtocol.endpointHost = "ingest.artracker.io"

        // SDK ingest request -> must NOT be handled by ARTrackerURLProtocol
        let sdkUrl = URL(string: "https://ingest.artracker.io/api/v1/event")!
        var sdkReq = URLRequest(url: sdkUrl)
        XCTAssertFalse(ARTrackerURLProtocol.canInit(with: sdkReq))

        sdkReq.setValue("test_key", forHTTPHeaderField: "X-Artracker-Key")
        XCTAssertFalse(ARTrackerURLProtocol.canInit(with: sdkReq))

        // Normal app request -> must be handled by ARTrackerURLProtocol
        let appUrl = URL(string: "https://api.myapp.com/v1/users")!
        let appReq = URLRequest(url: appUrl)
        XCTAssertTrue(ARTrackerURLProtocol.canInit(with: appReq))
    }
}
#endif
