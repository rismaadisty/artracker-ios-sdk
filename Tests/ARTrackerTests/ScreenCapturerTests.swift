import XCTest
@testable import ARTracker
#if canImport(UIKit)
import UIKit

final class ScreenCapturerTests: XCTestCase {

    @MainActor
    private func createTestWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let label = UILabel(frame: CGRect(x: 20, y: 20, width: 200, height: 40))
        label.text = "ScreenCapturerTest"
        window.addSubview(label)
        window.isHidden = false
        return window
    }

    @MainActor
    func testNilPeriodicFpsStopsTimerButImmediateWorks() {
        let capturer = ScreenCapturer(quality: .standard, fps: 2.0)
        let window = createTestWindow()
        capturer.isAppActive = { true }
        capturer.windowProvider = { [window] }

        var capturedFrames: [ScreenFramePayload] = []
        capturer.onFrameCaptured = { frame in
            capturedFrames.append(frame)
        }

        capturer.start()
        capturer.setPeriodicFps(nil)

        // Give timer loop 0.5s to verify no frames captured automatically
        let exp = expectation(description: "No timer capture")
        exp.isInverted = true
        wait(for: [exp], timeout: 0.5)
        capturer.flushEncodeQueueForTesting()
        XCTAssertEqual(capturedFrames.count, 0)

        // captureImmediate should still work
        capturer.captureImmediate(triggerReason: "test.immediate", force: true)
        capturer.flushEncodeQueueForTesting()
        XCTAssertEqual(capturedFrames.count, 1)

        capturer.stop()
    }

    @MainActor
    func testForcedCaptureBypassesDedup() {
        let capturer = ScreenCapturer(quality: .standard, fps: 2.0)
        let window = createTestWindow()
        capturer.isAppActive = { true }
        capturer.windowProvider = { [window] }

        var capturedFrames: [ScreenFramePayload] = []
        capturer.onFrameCaptured = { frame in
            capturedFrames.append(frame)
        }

        capturer.start()
        capturer.setPeriodicFps(nil) // stop timer so only manual triggers run

        // First capture
        capturer.captureImmediate(triggerReason: "1", force: false)
        capturer.flushEncodeQueueForTesting()
        XCTAssertEqual(capturedFrames.count, 1)

        // Second identical capture without force: should be deduped (0 extra frames)
        capturer.captureImmediate(triggerReason: "2", force: false)
        capturer.flushEncodeQueueForTesting()
        XCTAssertEqual(capturedFrames.count, 1)

        // Third identical capture with force: true -> bypasses dedup!
        capturer.captureImmediate(triggerReason: "3", force: true)
        capturer.flushEncodeQueueForTesting()
        XCTAssertEqual(capturedFrames.count, 2)

        capturer.stop()
    }

    @MainActor
    func testUpdateFpsCapWhileNilDoesNotRestartTimer() {
        let capturer = ScreenCapturer(quality: .standard, fps: 2.0)
        let window = createTestWindow()
        capturer.isAppActive = { true }
        capturer.windowProvider = { [window] }

        var capturedFrames: [ScreenFramePayload] = []
        capturer.onFrameCaptured = { frame in
            capturedFrames.append(frame)
        }

        capturer.start()
        capturer.setPeriodicFps(nil)

        // Call updateFpsCap
        capturer.updateFpsCap(4.0)

        let exp = expectation(description: "No timer capture after updateFpsCap")
        exp.isInverted = true
        wait(for: [exp], timeout: 0.5)
        capturer.flushEncodeQueueForTesting()
        XCTAssertEqual(capturedFrames.count, 0)

        capturer.stop()
    }

    @MainActor
    func testMaskFailureDropsFrame() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let label = UILabel(frame: CGRect(x: 10, y: 10, width: 100, height: 30))
        label.text = "Secret"
        window.addSubview(label)
        window.isHidden = false

        let capturer = ScreenCapturer(quality: .standard, fps: 2.0, maskAllText: false)
        capturer.windowProvider = { [window] }
        capturer.isAppActive = { true }

        struct MaskCollectionError: Error {}
        capturer.maskCollector = { _, _ in
            throw MaskCollectionError()
        }

        var capturedFrames: [ScreenFramePayload] = []
        capturer.onFrameCaptured = { frame in
            capturedFrames.append(frame)
        }

        capturer.start()
        capturer.captureImmediate(force: true)
        capturer.flushEncodeQueueForTesting()
        capturer.stop()

        XCTAssertTrue(capturedFrames.isEmpty, "Frame must be dropped and never encoded when mask collection throws")
    }
}
#endif
