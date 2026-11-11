import Foundation
#if canImport(UIKit)
import UIKit

/// High-performance main-thread screen capturer for `artracker-screen-v1` screenshot replay mode.
@MainActor
public final class ScreenCapturer {
    public var quality: ReplayQuality
    public var targetFps: Double
    public private(set) var effectiveFps: Double
    public var maskAllText: Bool
    public var onFrameCaptured: ((ScreenFramePayload) -> Void)?

    private var timer: DispatchSourceTimer?
    private var isRunning: Bool = false
    private var isPaused: Bool = false

    // Watchdog
    private var slowCaptureCount: Int = 0
    private var lastSlowCaptureUptime: TimeInterval = 0

    // Duplicate suppression
    private var lastFrameHash: UInt32?

    // Keyboard tracking
    private var keyboardFrame: CGRect?
    private var isKeyboardVisible: Bool = false

    // Active screen name
    private var currentScreenName: String = "App"

    // Background worker for JPEG compression + base64 encoding
    private let encodeQueue = DispatchQueue(label: "com.artracker.replay.encoder", qos: .userInitiated)

    public init(
        quality: ReplayQuality = .standard,
        fps: Double = 2.0,
        maskAllText: Bool = false
    ) {
        self.quality = quality
        let clampedFps = max(0.5, min(fps, 10.0))
        self.targetFps = clampedFps
        self.effectiveFps = clampedFps
        self.maskAllText = maskAllText

        setupNotificationObservers()
    }

    public func setScreenName(_ name: String) {
        self.currentScreenName = name
    }

    public func updateFpsCap(_ maxFps: Double) {
        let newTarget = min(self.targetFps, maxFps)
        if newTarget != self.targetFps {
            self.targetFps = max(0.5, min(newTarget, 10.0))
            self.effectiveFps = min(self.effectiveFps, self.targetFps)
            if isRunning && !isPaused {
                restartTimer()
            }
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        restartTimer()
    }

    public func stop() {
        isRunning = false
        isPaused = false
        timer?.cancel()
        timer = nil
    }

    public func captureImmediate(triggerReason: String? = nil) {
        guard isRunning else { return }
        performCapture()
    }

    // MARK: - Lifecycle & Notifications

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pauseTimer()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pauseTimer()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeTimer()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }

        // Keyboard tracking
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    self?.keyboardFrame = frame
                    self?.isKeyboardVisible = frame.height > 0 && frame.origin.y < (UIScreen.main.bounds.height - 10)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isKeyboardVisible = false
                self?.keyboardFrame = nil
            }
        }
    }

    private func pauseTimer() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        timer?.cancel()
        timer = nil
    }

    private func resumeTimer() {
        guard isRunning, isPaused else { return }
        isPaused = false
        restartTimer()
        performCapture()
    }

    private func restartTimer() {
        timer?.cancel()
        timer = nil

        let intervalMs = Int((1.0 / effectiveFps) * 1000.0)
        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        newTimer.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        newTimer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.performCapture()
            }
        }
        newTimer.resume()
        self.timer = newTimer
    }

    // MARK: - Capture Core

    private func performCapture() {
        // Strict GPU & Background Guard: prevent 0xbaadca11 termination
        guard UIApplication.shared.applicationState == .active else {
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let windows = getVisibleWindows()
        guard let primaryWindow = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            return
        }

        let canvasBounds = primaryWindow.bounds
        guard canvasBounds.width > 0 && canvasBounds.height > 0 else {
            return
        }

        // Direct target scale computation: never upscale
        let screenScale = primaryWindow.screen.scale
        let minDimension = min(canvasBounds.width, canvasBounds.height)
        let targetScale = min(screenScale, quality.shortSidePx / max(minDimension, 1.0))

        let format = UIGraphicsImageRendererFormat()
        format.scale = targetScale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(bounds: canvasBounds, format: format)

        var maskCheckFailed = false
        var hasMaskedContent = false

        // Check if active first responder is sensitive
        let isFirstResponderSensitive = windows.contains { window in
            MaskingRules.isSensitiveFirstResponderActive(in: window, maskAllText: self.maskAllText)
        }

        let capturedImage = renderer.image { ctx in
            // 1. Draw all visible windows in windowLevel order
            for window in windows {
                ctx.cgContext.saveGState()
                // Align window coordinate system to canvas
                let originInCanvas = primaryWindow.convert(window.bounds.origin, from: window)
                ctx.cgContext.translateBy(x: originInCanvas.x, y: originInCanvas.y)
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                ctx.cgContext.restoreGState()
            }

            // 2. Keyboard masking: if active first responder is sensitive, mask keyboard area
            if isFirstResponderSensitive, let kFrame = self.keyboardFrame, self.isKeyboardVisible {
                let convertedKFrame = primaryWindow.convert(kFrame, from: nil)
                let intersection = convertedKFrame.intersection(canvasBounds)
                if !intersection.isNull && !intersection.isEmpty {
                    hasMaskedContent = true
                    drawMaskBlock(in: intersection, context: ctx.cgContext)
                }
            }

            // 3. Collect and paint all masked view rects
            do {
                for window in windows {
                    let rects = MaskingRules.collectMaskRects(in: window, maskAllText: self.maskAllText)
                    for rect in rects {
                        let canvasRect = primaryWindow.convert(rect, from: window)
                        let clipped = canvasRect.intersection(canvasBounds)
                        if !clipped.isNull && !clipped.isEmpty {
                            hasMaskedContent = true
                            drawMaskBlock(in: clipped, context: ctx.cgContext)
                        }
                    }
                }
            } catch {
                // If mask collection throws, mark failed to drop frame
                maskCheckFailed = true
            }
        }

        // A frame whose mask collection throws is dropped, never sent unmasked
        guard !maskCheckFailed else {
            return
        }

        let captureElapsed = CFAbsoluteTimeGetCurrent() - startTime
        handleWatchdog(captureElapsed: captureElapsed)

        // Duplicate suppression: 64x64 CRC
        if let frameHash = compute64x64Hash(image: capturedImage) {
            if frameHash == self.lastFrameHash {
                // Duplicate frame detected: skip encoding
                return
            }
            self.lastFrameHash = frameHash
        }

        // Package frame metadata
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let screen = self.currentScreenName
        let pixelWidth = Int((canvasBounds.width * targetScale).rounded())
        let pixelHeight = Int((canvasBounds.height * targetScale).rounded())
        let viewportWidth = Double(canvasBounds.width)
        let viewportHeight = Double(canvasBounds.height)
        let jpegQuality = quality.jpegQuality
        let masked = hasMaskedContent

        // Offload JPEG encoding + Base64 conversion to background queue
        encodeQueue.async { [weak self] in
            guard let jpegData = capturedImage.jpegData(compressionQuality: jpegQuality) else {
                return
            }
            let base64 = jpegData.base64EncodedString()
            let payload = ScreenFramePayload(
                ts: ts,
                screen: screen,
                w: pixelWidth,
                h: pixelHeight,
                vw: viewportWidth,
                vh: viewportHeight,
                mime: "image/jpeg",
                data: base64,
                masked: masked
            )

            self?.onFrameCaptured?(payload)
        }
    }

    private func drawMaskBlock(in rect: CGRect, context: CGContext) {
        context.saveGState()
        // Solid opaque dark slate mask matching privacy standard
        context.setFillColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1.0)
        context.fill(rect)
        context.restoreGState()
    }

    private func getVisibleWindows() -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        let sceneWindows = scenes.flatMap { $0.windows }
        let allWindows = sceneWindows.isEmpty ? UIApplication.shared.windows : sceneWindows

        return allWindows
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    // MARK: - Watchdog

    private func handleWatchdog(captureElapsed: TimeInterval) {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if captureElapsed > 0.016 { // > 16ms of main-thread time
            slowCaptureCount += 1
            lastSlowCaptureUptime = nowUptime
            if slowCaptureCount >= 3 {
                // Halve fps (min 0.5)
                let newFps = max(0.5, effectiveFps / 2.0)
                if newFps != effectiveFps {
                    effectiveFps = newFps
                    restartTimer()
                }
                slowCaptureCount = 0
            }
        } else {
            // Restore fps after 10s without a slow capture
            if effectiveFps < targetFps && (nowUptime - lastSlowCaptureUptime >= 10.0) {
                effectiveFps = targetFps
                restartTimer()
            }
        }
    }

    // MARK: - Duplicate Detection (64x64 Grayscale CRC)

    private func compute64x64Hash(image: UIImage) -> UInt32? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 64
        let height = 64
        var pixelData = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixelData.withUnsafeBytes { raw in
            CRC32.checksum(data: Data(raw))
        }
    }

    deinit {
        timer?.cancel()
    }
}
#endif

