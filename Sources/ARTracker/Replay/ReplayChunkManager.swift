import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages buffering of ScreenFramePayload and ScreenTouchPoint, 10s rotation,
/// Gzip compression, persistent disk queue in Caches, and uploading to backend / R2.
public final class ReplayChunkManager: @unchecked Sendable {
    private let lock = UnfairLock()
    private let uploader: ReplayUploader
    private let environment: String
    private let wifiOnly: Bool
    private let diskQueue: ReplayDiskQueue
    private let workerQueue = DispatchQueue(label: "com.artracker.replay.worker", qos: .utility)

    // Shared monotonic sequence counter
    private var currentChunkSeq: Int = 0

    // Screenshot buffers
    private var screenFrameBuffer: [ScreenFramePayload] = []
    private var screenTouchBuffer: [ScreenTouchPoint] = []

    private var chunkStartTime: Date = Date()
    private var chunkStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var hasError: Bool = false
    private var hasRageClick: Bool = false
    private var flushTimer: DispatchSourceTimer?
    private var isFlushing: Bool = false

    // Callbacks
    public var onScreenshotDisabled: (@Sendable () -> Void)?
    public var onBudgetGovernorAlert: (@Sendable (_ shouldHalveFps: Bool, _ shouldStepDownQuality: Bool) -> Void)?

    public init(
        uploader: ReplayUploader,
        environment: String,
        wifiOnly: Bool = false,
        diskQueue: ReplayDiskQueue = ReplayDiskQueue()
    ) {
        self.uploader = uploader
        self.environment = environment
        self.wifiOnly = wifiOnly
        self.diskQueue = diskQueue
        startFlushTimer()
        processPendingUploads(completion: nil)
    }

    public func markError() {
        lock.withLock {
            self.hasError = true
        }
    }

    public func markRageClick() {
        lock.withLock {
            self.hasRageClick = true
        }
    }

    // MARK: - Screenshot Appending

    public func appendScreenFrame(_ frame: ScreenFramePayload) {
        lock.withLock {
            screenFrameBuffer.append(frame)
            if screenFrameBuffer.count >= 20 {
                triggerFlushLocked()
            }
        }
    }

    public func appendScreenTouch(_ touch: ScreenTouchPoint) {
        lock.withLock {
            screenTouchBuffer.append(touch)
            if screenFrameBuffer.count >= 20 || screenTouchBuffer.count >= 200 {
                triggerFlushLocked()
            }
        }
    }

    public func flush(completion: (@Sendable () -> Void)? = nil) {
        workerQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            self.lock.withLock {
                self.triggerFlushLocked()
            }
            self.processPendingUploads(completion: completion)
        }
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            self?.lock.withLock {
                self?.triggerFlushLocked()
            }
            self?.processPendingUploads(completion: nil)
        }
        timer.resume()
        self.flushTimer = timer
    }

    private func triggerFlushLocked() {
        guard !screenFrameBuffer.isEmpty || !screenTouchBuffer.isEmpty else { return }

        let nowUptime = ProcessInfo.processInfo.systemUptime
        let durationMs = max(100.0, (nowUptime - chunkStartUptime) * 1000.0)
        let sTime = ISO8601DateFormatter().string(from: chunkStartTime)
        let chunkHasErr = hasError
        let chunkHasRage = hasRageClick

        let framesToUpload = screenFrameBuffer
        let touchesToUpload = screenTouchBuffer
        screenFrameBuffer.removeAll(keepingCapacity: true)
        screenTouchBuffer.removeAll(keepingCapacity: true)

        chunkStartTime = Date()
        chunkStartUptime = nowUptime
        hasError = false
        hasRageClick = false

        let seq = currentChunkSeq
        currentChunkSeq += 1

        let payload = ScreenChunkPayload(
            format: "artracker-screen-v1",
            platform: "ios",
            seq: seq,
            frames: framesToUpload,
            touches: touchesToUpload
        )

        if let jsonData = try? JSONEncoder().encode(payload),
           let gzipped = try? Gzip.compress(data: jsonData) {
            let totalEvents = framesToUpload.count + touchesToUpload.count
            let item = ReplayQueueItem(
                seq: seq,
                format: "artracker-screen-v1",
                count: totalEvents,
                duration: durationMs,
                hasError: chunkHasErr,
                hasRage: chunkHasRage,
                startTime: sTime,
                data: gzipped
            )
            diskQueue.enqueue(item)

            // Budget governor evaluation
            let halveFps = diskQueue.shouldHalveFps()
            let stepDown = diskQueue.shouldStepDownQuality()
            if halveFps || stepDown {
                onBudgetGovernorAlert?(halveFps, stepDown)
            }
        }
    }

    private func processPendingUploads(completion: (@Sendable () -> Void)? = nil) {
        workerQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            // Check wifiOnly constraint
            if !Reachability.shared.canUpload(wifiOnly: self.wifiOnly) {
                completion?()
                return
            }

            let item = self.lock.withLock { () -> ReplayQueueItem? in
                guard !self.isFlushing else { return nil }
                guard let nextItem = self.diskQueue.peekNext() else { return nil }
                self.isFlushing = true
                return nextItem
            }

            guard let queueItem = item else {
                completion?()
                return
            }

            let sessionId = SessionManager.shared.sessionId
            let userId = SessionManager.shared.userId

            #if canImport(UIKit)
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "artracker.replay.upload") {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
            #endif

            self.uploader.requestChunkUrl(
                sessionId: sessionId,
                chunkSeq: queueItem.seq,
                sizeBytes: queueItem.data.count,
                userId: userId,
                environment: self.environment,
                startTime: queueItem.startTime,
                format: queueItem.format
            ) { [weak self] result in
                guard let self = self else {
                    #if canImport(UIKit)
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                    #endif
                    return
                }

                switch result {
                case .success(let (uploadUrl, _)):
                    self.uploader.uploadGzipData(uploadUrl: uploadUrl, gzipData: queueItem.data) { uploadResult in
                        switch uploadResult {
                        case .success:
                            self.uploader.acknowledgeChunk(
                                sessionId: sessionId,
                                chunkSeq: queueItem.seq,
                                sizeBytes: queueItem.data.count,
                                durationMs: queueItem.duration,
                                eventCount: queueItem.count,
                                hasError: queueItem.hasError,
                                hasRageClick: queueItem.hasRage
                            ) { _ in
                                self.diskQueue.remove(id: queueItem.id)
                                self.lock.withLock { self.isFlushing = false }
                                #if canImport(UIKit)
                                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                                #endif
                                self.processPendingUploads(completion: completion)
                            }
                        case .failure:
                            self.lock.withLock { self.isFlushing = false }
                            #if canImport(UIKit)
                            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                            #endif
                            completion?()
                        }
                    }

                case .failure(let error):
                    if case ReplayUploadError.screenshotDisabled = error {
                        self.diskQueue.clearScreenshotChunks()
                        self.onScreenshotDisabled?()
                    }

                    self.lock.withLock { self.isFlushing = false }
                    #if canImport(UIKit)
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                    #endif
                    completion?()
                }
            }
        }
    }

    deinit {
        flushTimer?.cancel()
    }
}
