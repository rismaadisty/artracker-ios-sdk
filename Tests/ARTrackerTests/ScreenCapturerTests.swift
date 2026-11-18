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

    private func samplePixelRGB(in cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return (0, 0, 0)
        }
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return (pixel[0], pixel[1], pixel[2])
    }

    @MainActor
    func testSecureFieldFirstResponderMasksKeyboardArea() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.backgroundColor = .white
        let secureField = UITextField(frame: CGRect(x: 20, y: 40, width: 200, height: 40))
        secureField.isSecureTextEntry = true
        window.addSubview(secureField)
        window.isHidden = false

        let capturer = ScreenCapturer(quality: .standard, fps: 2.0, maskAllText: false)
        capturer.windowProvider = { [window] }
        capturer.isAppActive = { true }
        capturer.isSensitiveFirstResponderChecker = { _, _ in true }
        // Simulasikan keyboard tampil di bagian bawah layar (y: 260..480)
        capturer.setKeyboardFrameForTesting(CGRect(x: 0, y: 260, width: 320, height: 220))

        var capturedFrames: [ScreenFramePayload] = []
        capturer.onFrameCaptured = { frame in
            capturedFrames.append(frame)
        }

        capturer.start()
        capturer.setPeriodicFps(nil)
        capturer.captureImmediate(force: true)
        capturer.flushEncodeQueueForTesting()
        capturer.stop()

        let frame = try XCTUnwrap(capturedFrames.first)
        XCTAssertEqual(frame.masked, true)

        let jpegData = try XCTUnwrap(Data(base64Encoded: frame.data))
        let image = try XCTUnwrap(UIImage(data: jpegData))
        let cgImage = try XCTUnwrap(image.cgImage)
        let sampleY = Int(Double(cgImage.height) * 0.8)
        let sampleX = cgImage.width / 2
        let pixel = samplePixelRGB(in: cgImage, x: sampleX, y: sampleY)
        XCTAssertLessThan(pixel.r, 80)
        XCTAssertLessThan(pixel.g, 80)
        XCTAssertLessThan(pixel.b, 90)
    }

    @MainActor
    func testMaskAllTextMasksSwiftUIHostingViewArea() throws {
        final class _UIHostingViewContainerStub: UIView {}

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.backgroundColor = .white
        let hostingView = _UIHostingViewContainerStub(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        hostingView.backgroundColor = .white
        window.addSubview(hostingView)
        window.isHidden = false

        let capturer = ScreenCapturer(quality: .standard, fps: 2.0, maskAllText: true)
        capturer.windowProvider = { [window] }
        capturer.isAppActive = { true }

        var capturedFrames: [ScreenFramePayload] = []
        capturer.onFrameCaptured = { frame in
            capturedFrames.append(frame)
        }

        capturer.start()
        capturer.setPeriodicFps(nil)
        capturer.captureImmediate(force: true)
        capturer.flushEncodeQueueForTesting()
        capturer.stop()

        let frame = try XCTUnwrap(capturedFrames.first)
        XCTAssertEqual(frame.masked, true)

        let jpegData = try XCTUnwrap(Data(base64Encoded: frame.data))
        let image = try XCTUnwrap(UIImage(data: jpegData))
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixel = samplePixelRGB(in: cgImage, x: cgImage.width / 2, y: cgImage.height / 2)
        XCTAssertLessThan(pixel.r, 80)
        XCTAssertLessThan(pixel.g, 80)
        XCTAssertLessThan(pixel.b, 90)
    }

    @MainActor
    func testWatchdogHalvesFpsAfterThreeSlowCapturesAndRecoversAfterTenSeconds() {
        let capturer = ScreenCapturer(quality: .standard, fps: 4.0)
        XCTAssertEqual(capturer.effectiveFps, 4.0)
        XCTAssertEqual(capturer.targetFps, 4.0)

        // 2 slow captures (> 16ms): belum menurunkan FPS
        capturer.handleWatchdog(captureElapsed: 0.020, now: 100.0)
        capturer.handleWatchdog(captureElapsed: 0.020, now: 100.5)
        XCTAssertEqual(capturer.effectiveFps, 4.0)

        // Slow capture ke-3 berturut-turut -> effectiveFps turun separuh menjadi 2.0, targetFps tetap 4.0
        capturer.handleWatchdog(captureElapsed: 0.020, now: 101.0)
        XCTAssertEqual(capturer.effectiveFps, 2.0)
        XCTAssertEqual(capturer.targetFps, 4.0)

        // Capture cepat sebelum 10 detik (t = 105.0) -> belum pulih
        capturer.handleWatchdog(captureElapsed: 0.005, now: 105.0)
        XCTAssertEqual(capturer.effectiveFps, 2.0)

        // Capture cepat setelah >= 10 detik tanpa slow capture (t = 111.1) -> pulih ke targetFps (4.0)
        capturer.handleWatchdog(captureElapsed: 0.005, now: 111.1)
        XCTAssertEqual(capturer.effectiveFps, 4.0)
    }

    @MainActor
    func testHalveEffectiveFpsPreservesTargetFpsAndClampsAtHalfFps() {
        let capturer = ScreenCapturer(quality: .high, fps: 2.0)
        capturer.halveEffectiveFps()
        XCTAssertEqual(capturer.effectiveFps, 1.0)
        XCTAssertEqual(capturer.targetFps, 2.0)

        capturer.halveEffectiveFps()
        XCTAssertEqual(capturer.effectiveFps, 0.5)

        // Tidak boleh turun di bawah 0.5 FPS
        capturer.halveEffectiveFps()
        XCTAssertEqual(capturer.effectiveFps, 0.5)
        XCTAssertEqual(capturer.targetFps, 2.0)
    }
}
#endif
