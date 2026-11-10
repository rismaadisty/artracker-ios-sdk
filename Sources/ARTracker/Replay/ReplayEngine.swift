import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Main Replay Engine orchestrating WireframeCrawler, TouchTracker, and ReplayChunkManager.
public final class ReplayEngine: @unchecked Sendable {
    public static let shared = ReplayEngine()

    private let lock = UnfairLock()
    private var chunkManager: ReplayChunkManager?
    private var isStarted: Bool = false
    private var maskAllText: Bool = false
    private var lastCapturedTree: MobileViewNode?
    private var lastSnapshotUptime: TimeInterval = 0
    private var pendingDebounceWorkItem: DispatchWorkItem?

    private let workerQueue = DispatchQueue(label: "com.artracker.replay.engine", qos: .utility)

    private init() {}

    public func start(endpoint: URL, appKey: String, environment: String, maskAllText: Bool) {
        lock.withLock {
            guard !isStarted else { return }
            isStarted = true
            self.maskAllText = maskAllText

            let uploader = ReplayUploader(endpoint: endpoint, appKey: appKey)
            self.chunkManager = ReplayChunkManager(uploader: uploader, environment: environment)
        }

        #if canImport(UIKit)
        DispatchQueue.main.async { [weak self] in
            self?.setupTouchTracking()
            self?.setupWindowObserver()
            self?.attemptInitialCapture()
        }
        #endif
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
                self?.captureFullSnapshot(triggerReason: "window.didBecomeKey")
            }
        }
    }

    private func attemptInitialCapture() {
        Task { @MainActor in
            self.captureFullSnapshot(triggerReason: "session.start")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                self?.captureFullSnapshot(triggerReason: "session.start.delayed")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.flush()
        }
    }

    private func setupTouchTracking() {
        TouchTracker.shared.start { [weak self] point, isRageTap in
            guard let self = self else { return }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let touch = MobileTouchPoint(
                ts: nowMs,
                x: Double(point.x),
                y: Double(point.y),
                name: isRageTap ? "touch.rage_tap" : "touch.tap"
            )

            self.chunkManager?.appendTouch(touch)
            if isRageTap {
                self.chunkManager?.markRageClick()
            }

            // Debounce crawl 300ms after touch interaction to capture resulting UI transitions
            self.scheduleDebouncedCrawl()
        }
    }

    public func scheduleDebouncedCrawl() {
        lock.withLock {
            pendingDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.captureFullSnapshot(triggerReason: "touch.debounce")
                }
            }
            pendingDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    @MainActor
    public func captureFullSnapshot(triggerReason: String, screenName: String? = nil) {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let shouldThrottle = lock.withLock {
            if nowUptime - lastSnapshotUptime < 0.4 { return true }
            lastSnapshotUptime = nowUptime
            return false
        }
        if shouldThrottle { return }

        // Cari window aktif: prioritaskan isKeyWindow, fallback ke window pertama yang terlihat
        let allWindows = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })

        guard let window = allWindows.first(where: { $0.isKeyWindow })
            ?? allWindows.first(where: { !$0.isHidden })
            ?? allWindows.first else {
            return
        }

        let mask = self.maskAllText

        // Stage 1: Fast primitive extraction (< 1.5ms) on MainActor
        let (tree, maskedCount) = WireframeCrawler.shared.captureWindowTree(
            window: window,
            maskAllText: mask
        )

        let rootName = window.rootViewController.map { String(describing: type(of: $0)) } ?? "MainScreen"
        let resolvedScreen = screenName ?? rootName
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Stage 2: Background processing
        workerQueue.async { [weak self] in
            guard let self = self else { return }

            // Deduplication check: if tree is identical to previous snapshot, skip
            let isIdentical = self.lock.withLock {
                if self.lastCapturedTree == tree {
                    return true
                }
                self.lastCapturedTree = tree
                return false
            }

            if isIdentical && triggerReason != "session.start" && triggerReason != "session.start.delayed" {
                return
            }

            let frame = MobileFramePayload(
                ts: timestampMs,
                screen: resolvedScreen,
                presentation: "push",
                maskedCount: maskedCount,
                viewTree: tree
            )

            self.chunkManager?.appendFrame(frame)
        }
    }
    #endif
}
