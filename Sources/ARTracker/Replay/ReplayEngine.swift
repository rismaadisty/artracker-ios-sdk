import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Main Replay Engine orchestrating ScreenCapturer, TouchTracker, CaptureActivityGovernor, and ReplayChunkManager
/// for high-fidelity visual session replays (`artracker-screen-v1`).
public final class ReplayEngine: @unchecked Sendable {
    public static let shared = ReplayEngine()

    private let lock = UnfairLock()
    private var chunkManager: ReplayChunkManager?
    private var isStarted: Bool = false
    private var maskAllText: Bool = false

    #if canImport(UIKit)
    @MainActor private var screenCapturer: ScreenCapturer?
    private var governor: CaptureActivityGovernor?
    private var transitionWorkItem: DispatchWorkItem?
    private var pendingTriggerWorkItem: DispatchWorkItem?
    private var delayedStartWorkItem: DispatchWorkItem?
    private var triggerDeadline: TimeInterval = 0
    private var observerTokens: [NSObjectProtocol] = []
    private var clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    private let frameCountLock = NSLock()
    private var _capturedFrameCount: Int = 0
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
        fps: Double = 2.0,
        idleAfterMs: Int64 = 30_000,
        dormantAfterMs: Int64 = 180_000
    ) {
        let uploader = ReplayUploader(endpoint: endpoint, appKey: appKey)
        let diskQueue = ReplayDiskQueue()
        let mgr = ReplayChunkManager(
            uploader: uploader,
            environment: environment,
            wifiOnly: wifiOnly,
            diskQueue: diskQueue
        )

        startInternal(
            chunkManager: mgr,
            uploader: uploader,
            maskAllText: maskAllText,
            quality: quality,
            fps: fps,
            idleAfterMs: idleAfterMs,
            dormantAfterMs: dormantAfterMs,
            clock: { Int64(Date().timeIntervalSince1970 * 1000) }
        )
    }

    #if canImport(UIKit)
    private func startInternal(
        chunkManager: ReplayChunkManager,
        uploader: ReplayUploader,
        maskAllText: Bool,
        quality: ReplayQuality = .standard,
        fps: Double = 2.0,
        idleAfterMs: Int64 = 30_000,
        dormantAfterMs: Int64 = 180_000,
        clock: @escaping @Sendable () -> Int64,
        windowProvider: (() -> [UIWindow])? = nil,
        isAppActive: (() -> Bool)? = nil
    ) {
        lock.withLock {
            guard !isStarted else { return }
            isStarted = true
            self.maskAllText = maskAllText
            self.chunkManager = chunkManager
        }

        chunkManager.onScreenshotDisabled = { [weak self] in
            UserDefaults.standard.set(false, forKey: "artracker.replay.screenshot_enabled")
            Task { @MainActor [weak self] in
                self?.screenCapturer?.stop()
            }
        }

        chunkManager.onBudgetGovernorAlert = { [weak self] shouldHalveFps, shouldStepDownQuality in
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

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.setupMainActorComponents(
                    fps: fps,
                    idleAfterMs: idleAfterMs,
                    dormantAfterMs: dormantAfterMs,
                    quality: quality,
                    maskAllText: maskAllText,
                    windowProvider: windowProvider,
                    isAppActive: isAppActive,
                    clock: clock
                )
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setupMainActorComponents(
                    fps: fps,
                    idleAfterMs: idleAfterMs,
                    dormantAfterMs: dormantAfterMs,
                    quality: quality,
                    maskAllText: maskAllText,
                    windowProvider: windowProvider,
                    isAppActive: isAppActive,
                    clock: clock
                )
            }
        }

        uploader.fetchReplayConfig { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let config):
                UserDefaults.standard.set(config.screenshotEnabled, forKey: "artracker.replay.screenshot_enabled")
                DispatchQueue.main.async {
                    if let maxFps = config.maxFps {
                        self.screenCapturer?.updateFpsCap(maxFps)
                    }
                    if !config.screenshotEnabled {
                        self.screenCapturer?.stop()
                    }
                }
            case .failure(let error):
                if case ReplayUploadError.screenshotDisabled = error {
                    UserDefaults.standard.set(false, forKey: "artracker.replay.screenshot_enabled")
                    DispatchQueue.main.async {
                        self.screenCapturer?.stop()
                    }
                }
            }
        }
    }
    #else
    private func startInternal(
        chunkManager: ReplayChunkManager,
        uploader: ReplayUploader,
        maskAllText: Bool,
        quality: ReplayQuality = .standard,
        fps: Double = 2.0,
        idleAfterMs: Int64 = 30_000,
        dormantAfterMs: Int64 = 180_000,
        clock: @escaping @Sendable () -> Int64
    ) {
        lock.withLock {
            guard !isStarted else { return }
            isStarted = true
            self.maskAllText = maskAllText
            self.chunkManager = chunkManager
        }
    }
    #endif

    public func markError() {
        chunkManager?.markError()
        #if canImport(UIKit)
        Task { @MainActor [weak self] in
            self?.trigger(.error)
        }
        #endif
    }

    public func flush(completion: (@Sendable () -> Void)? = nil) {
        chunkManager?.flush(completion: completion)
    }

    #if canImport(UIKit)
    @MainActor
    private func setupMainActorComponents(
        fps: Double,
        idleAfterMs: Int64,
        dormantAfterMs: Int64,
        quality: ReplayQuality,
        maskAllText: Bool,
        windowProvider: (() -> [UIWindow])?,
        isAppActive: (() -> Bool)?,
        clock: @escaping @Sendable () -> Int64
    ) {
        self.clock = clock
        let gov = CaptureActivityGovernor(
            activeFps: fps,
            idleAfterMs: idleAfterMs,
            dormantAfterMs: dormantAfterMs
        )
        let startNow = clock()
        gov.onStart(nowMs: startNow)
        self.governor = gov

        let capturer = ScreenCapturer(
            quality: quality,
            fps: fps,
            maskAllText: maskAllText
        )
        if let wp = windowProvider {
            capturer.windowProvider = wp
        }
        if let ia = isAppActive {
            capturer.isAppActive = ia
        }
        capturer.onFrameCaptured = { [weak self] frame in
            guard let self = self else { return }
            self.chunkManager?.appendScreenFrame(frame)
            self.frameCountLock.withLock {
                self._capturedFrameCount += 1
            }
            Task { @MainActor [weak self] in
                if self?.governor?.state == .dormant {
                    self?.chunkManager?.scheduleOneShotFlush(after: 10.0)
                }
            }
        }
        self.screenCapturer = capturer
        capturer.start()
        capturer.captureImmediate(triggerReason: "session.start")

        self.applyGovernorState(now: startNow)
        self.scheduleNextTransition()

        self.setupTouchTracking()
        self.setupWindowObserver()
        self.setupAppLifecycleObservers()

        let delayedItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self, self.governor?.state == .active else { return }
                self.screenCapturer?.captureImmediate(triggerReason: "session.start.delayed")
            }
        }
        self.delayedStartWorkItem = delayedItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: delayedItem)
    }

    @MainActor
    private func applyGovernorState(now: Int64) {
        guard let governor = self.governor else { return }
        let fps = governor.periodicFps()
        screenCapturer?.setPeriodicFps(fps)
        if governor.state != .active {
            delayedStartWorkItem?.cancel()
            delayedStartWorkItem = nil
        }
        if governor.state == .dormant {
            chunkManager?.flush()
            chunkManager?.pauseFlushTimer()
        }
    }

    @MainActor
    private func scheduleNextTransition() {
        transitionWorkItem?.cancel()
        guard let governor = self.governor, let nextMs = governor.nextTransitionAtMs() else { return }
        let nowMs = clock()
        let delayMs = max(0, nextMs - nowMs)
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, let governor = self.governor else { return }
                let currentNow = self.clock()
                let oldState = governor.state
                governor.evaluate(nowMs: currentNow)
                if governor.state != oldState {
                    self.applyGovernorState(now: currentNow)
                }
                self.scheduleNextTransition()
            }
        }
        self.transitionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    @MainActor
    public func trigger(_ kind: TriggerKind) {
        guard isStarted else { return }
        guard !SessionManager.shared.isExpired else { return }
        guard let governor = self.governor else { return }

        let nowMs = clock()
        let oldState = governor.state
        guard let delayMs = governor.admitTrigger(kind, nowMs: nowMs) else {
            return
        }

        if governor.state != oldState {
            applyGovernorState(now: nowMs)
            scheduleNextTransition()
        }

        let shouldForce = (kind == .manual || kind == .screen)

        if delayMs == 0 {
            // Synchronous execution for manual trigger
            pendingTriggerWorkItem?.cancel()
            pendingTriggerWorkItem = nil
            screenCapturer?.captureImmediate(triggerReason: "trigger.\(kind.rawValue)", force: shouldForce)
        } else {
            // Coalesce debounced triggers: shortest deadline wins
            let deadline = ProcessInfo.processInfo.systemUptime + (Double(delayMs) / 1000.0)
            if pendingTriggerWorkItem != nil, deadline >= self.triggerDeadline {
                return
            }
            pendingTriggerWorkItem?.cancel()
            self.triggerDeadline = deadline
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.pendingTriggerWorkItem = nil
                    self.screenCapturer?.captureImmediate(triggerReason: "trigger.\(kind.rawValue)", force: shouldForce)
                }
            }
            self.pendingTriggerWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
        }
    }

    private func setupWindowObserver() {
        let t1 = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trigger(.window)
            }
        }
        let t2 = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trigger(.window)
            }
        }
        let t3 = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trigger(.keyboard)
            }
        }
        let t4 = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.trigger(.keyboard)
            }
        }
        observerTokens.append(contentsOf: [t1, t2, t3, t4])
    }

    private func setupAppLifecycleObservers() {
        let t1 = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidEnterBackground()
            }
        }
        let t2 = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidBecomeActive()
            }
        }
        observerTokens.append(contentsOf: [t1, t2])
    }

    @MainActor
    private func handleDidEnterBackground() {
        lock.withLock {
            pendingDebounceWorkItem?.cancel()
            pendingDebounceWorkItem = nil
        }
        delayedStartWorkItem?.cancel()
        delayedStartWorkItem = nil
        transitionWorkItem?.cancel()
        transitionWorkItem = nil
        pendingTriggerWorkItem?.cancel()
        pendingTriggerWorkItem = nil
        chunkManager?.flush()
        chunkManager?.pauseFlushTimer()
    }

    @MainActor
    private func handleDidBecomeActive() {
        SessionManager.shared.onForeground()
        let nowMs = clock()
        governor?.onUserInput(nowMs: nowMs)
        applyGovernorState(now: nowMs)
        screenCapturer?.captureImmediate(triggerReason: "app.foreground", force: true)
        chunkManager?.resumeFlushTimer()
        scheduleNextTransition()
    }

    @MainActor
    private func handleUserTouchDown(nowMs: Int64) {
        if let governor = self.governor, governor.onUserInput(nowMs: nowMs) {
            self.screenCapturer?.captureImmediate(triggerReason: "wake", force: true)
            self.chunkManager?.resumeFlushTimer()
        }
        self.applyGovernorState(now: nowMs)
        self.scheduleNextTransition()
    }

    private func setupTouchTracking() {
        TouchTracker.shared.setGestureHandler { [weak self] point, kind, isRageTap in
            guard let self = self else { return }

            let nowMs = self.clock()
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

            if kind == "down" {
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.handleUserTouchDown(nowMs: nowMs)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.handleUserTouchDown(nowMs: nowMs)
                    }
                }
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
        trigger(.screen)
    }

    // MARK: - Testing Hooks

    internal func resetForTesting() {
        lock.withLock {
            isStarted = false
            pendingDebounceWorkItem?.cancel()
            pendingDebounceWorkItem = nil
            chunkManager = nil
        }
        #if canImport(UIKit)
        MainActor.assumeIsolated {
            delayedStartWorkItem?.cancel()
            delayedStartWorkItem = nil
            transitionWorkItem?.cancel()
            transitionWorkItem = nil
            pendingTriggerWorkItem?.cancel()
            pendingTriggerWorkItem = nil
            screenCapturer?.stop()
            screenCapturer = nil
            governor = nil
            frameCountLock.withLock {
                _capturedFrameCount = 0
            }
            for token in observerTokens {
                NotificationCenter.default.removeObserver(token)
            }
            observerTokens.removeAll()
            TouchTracker.shared.setGestureHandler(nil)
        }
        #endif
    }

    internal func startForTesting(
        uploader: ReplayUploader,
        diskQueue: ReplayDiskQueue,
        environment: String = "test",
        maskAllText: Bool = false,
        quality: ReplayQuality = .standard,
        fps: Double = 2.0,
        idleAfterMs: Int64 = 30_000,
        dormantAfterMs: Int64 = 180_000,
        clock: @escaping @Sendable () -> Int64,
        windowProvider: (() -> [UIWindow])? = nil,
        isAppActive: (() -> Bool)? = nil
    ) {
        let mgr = ReplayChunkManager(
            uploader: uploader,
            environment: environment,
            wifiOnly: false,
            diskQueue: diskQueue
        )
        startInternal(
            chunkManager: mgr,
            uploader: uploader,
            maskAllText: maskAllText,
            quality: quality,
            fps: fps,
            idleAfterMs: idleAfterMs,
            dormantAfterMs: dormantAfterMs,
            clock: clock,
            windowProvider: windowProvider,
            isAppActive: isAppActive
        )
    }

    @MainActor
    internal var governorStateForTesting: CaptureState? {
        governor?.state
    }

    @MainActor
    internal var screenCapturerPeriodicFpsForTesting: Double? {
        governor?.periodicFps()
    }

    internal var capturedFrameCountForTesting: Int {
        frameCountLock.withLock { _capturedFrameCount }
    }

    @MainActor
    internal func flushCapturerForTesting() {
        screenCapturer?.flushEncodeQueueForTesting()
    }

    @MainActor
    internal func evaluateLifecycleForTesting() {
        guard let governor = self.governor else { return }
        let nowMs = clock()
        let oldState = governor.state
        governor.evaluate(nowMs: nowMs)
        if governor.state != oldState {
            applyGovernorState(now: nowMs)
        }
    }

    @MainActor
    internal func handleBackgroundForTesting() {
        handleDidEnterBackground()
    }
    #endif
}
