import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Main Replay Engine orchestrating ScreenCapturer, TouchTracker, and ReplayChunkManager
/// for high-fidelity visual session replays (`artracker-screen-v1`).
public final class ReplayEngine: @unchecked Sendable {
    public static let shared = ReplayEngine()

    private let lock = UnfairLock()
    private var chunkManager: ReplayChunkManager?
    private var isStarted: Bool = false
    private var maskAllText: Bool = false

    #if canImport(UIKit)
    @MainActor private var screenCapturer: ScreenCapturer?
    #endif

    private var pendingDebounceWorkItem: DispatchWorkItem?

    private init() {}

    public func start(
        endpoint: URL,
        appKey: String,
        environment: String,
        maskAllText: Bool,
        wifiOnly: Bool = false,
        quality: ReplayQuality = .standard,
        fps: Double = 2.0
    ) {
        let uploader = ReplayUploader(endpoint: endpoint, appKey: appKey)
        let diskQueue = ReplayDiskQueue()
        let mgr = ReplayChunkManager(
            uploader: uploader,
            environment: environment,
            wifiOnly: wifiOnly,
            diskQueue: diskQueue
        )

        lock.withLock {
            guard !isStarted else { return }
            isStarted = true
            self.maskAllText = maskAllText
            self.chunkManager = mgr
        }

        mgr.onScreenshotDisabled = { [weak self] in
            UserDefaults.standard.set(false, forKey: "artracker.replay.screenshot_enabled")
            #if canImport(UIKit)
            Task { @MainActor [weak self] in
                self?.screenCapturer?.stop()
            }
            #endif
        }

        #if canImport(UIKit)
        mgr.onBudgetGovernorAlert = { [weak self] shouldHalveFps, shouldStepDownQuality in
            Task { @MainActor in
                guard let capturer = self?.screenCapturer else { return }
                if shouldHalveFps {
                    capturer.updateFpsCap(max(0.5, capturer.effectiveFps / 2.0))
                }
                if shouldStepDownQuality {
                    capturer.quality = capturer.quality.lowerPreset
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let capturer = ScreenCapturer(
                quality: quality,
                fps: fps,
                maskAllText: maskAllText
            )
            capturer.onFrameCaptured = { [weak self] frame in
                self?.chunkManager?.appendScreenFrame(frame)
            }
            self.screenCapturer = capturer
            capturer.start()
            capturer.captureImmediate(triggerReason: "session.start")

            self.setupTouchTracking()
            self.setupWindowObserver()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                Task { @MainActor in
                    self?.screenCapturer?.captureImmediate(triggerReason: "session.start.delayed")
                }
            }
        }
        #endif

        // Fetch remote config asynchronously to resolve server-side max fps or switch
        uploader.fetchReplayConfig { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let config):
                UserDefaults.standard.set(config.screenshotEnabled, forKey: "artracker.replay.screenshot_enabled")
                #if canImport(UIKit)
                DispatchQueue.main.async {
                    if let maxFps = config.maxFps {
                        self.screenCapturer?.updateFpsCap(maxFps)
                    }
                    if !config.screenshotEnabled {
                        self.screenCapturer?.stop()
                    }
                }
                #endif
            case .failure(let error):
                if case ReplayUploadError.screenshotDisabled = error {
                    UserDefaults.standard.set(false, forKey: "artracker.replay.screenshot_enabled")
                    #if canImport(UIKit)
                    DispatchQueue.main.async {
                        self.screenCapturer?.stop()
                    }
                    #endif
                }
            }
        }
    }

    public func markError() {
        chunkManager?.markError()
    }

    public func flush(completion: (@Sendable () -> Void)? = nil) {
        chunkManager?.flush(completion: completion)
    }

    #if canImport(UIKit)
    private func setupWindowObserver() {
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenCapturer?.captureImmediate(triggerReason: "window.didBecomeKey")
            }
        }
    }

    private func setupTouchTracking() {
        TouchTracker.shared.start { [weak self] point, kind, isRageTap in
            guard let self = self else { return }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let touch = ScreenTouchPoint(
                ts: nowMs,
                x: Double(point.x),
                y: Double(point.y),
                kind: kind
            )
            self.chunkManager?.appendScreenTouch(touch)
            if isRageTap {
                self.chunkManager?.markRageClick()
            }
            if kind == "down" || kind == "up" {
                self.scheduleDebouncedScreenshot()
            }
        }
    }

    public func scheduleDebouncedScreenshot() {
        lock.withLock {
            pendingDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.screenCapturer?.captureImmediate(triggerReason: "touch.debounce")
                }
            }
            pendingDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    @MainActor
    public func captureFullSnapshot(triggerReason: String, screenName: String? = nil) {
        if let name = screenName {
            screenCapturer?.setScreenName(name)
        }
        screenCapturer?.captureImmediate(triggerReason: triggerReason)
    }
    #endif
}
