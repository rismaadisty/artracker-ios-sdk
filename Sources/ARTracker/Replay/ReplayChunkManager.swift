import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages buffering of ScreenFramePayload and ScreenTouchPoint, 10s rotation,
/// Gzip compression, persistent disk queue in Caches, and uploading to backend / R2.
public final class ReplayChunkManager: @unchecked Sendable {
    public static let maxChunkBytes: Int = 2 * 1024 * 1024

    private let lock = UnfairLock()
    private let uploader: any ReplayUploading
    private let environment: String
    private let wifiOnly: Bool
    private let diskQueue: ReplayDiskQueue
    private let sessionIdProvider: @Sendable () -> String
    private let workerQueue = DispatchQueue(label: "com.artracker.replay.worker", qos: .utility)

    // Shared monotonic sequence counter
    private var currentChunkSeq: Int = 0

    // Screenshot buffers
    private var screenFrameBuffer: [ScreenFramePayload] = []
    private var screenTouchBuffer: [ScreenTouchPoint] = []
    private var currentBufferBytes: Int = 0
    private var activeSessionId: String? = nil
    private var currentChunkSessionId: String? = nil

    private let uptimeProvider: @Sendable () -> TimeInterval
    private let dateProvider: @Sendable () -> Date
    private var sessionStartTime: Date
    private var sessionStartUptime: TimeInterval
    private var hasError: Bool = false
    private var hasRageClick: Bool = false
    private var flushTimer: DispatchSourceTimer?
    private var oneShotFlushTimer: DispatchSourceTimer?
    private var isFlushing: Bool = false
    private var isScreenshotDisabled: Bool = false
    private var retryNotBeforeUptime: TimeInterval = 0

    // Callbacks
    public var onScreenshotDisabled: (@Sendable () -> Void)?
    public var onBudgetGovernorAlert: (@Sendable (_ shouldHalveFps: Bool, _ shouldStepDownQuality: Bool) -> Void)?

    public init(
        uploader: any ReplayUploading,
        environment: String,
        wifiOnly: Bool = false,
        diskQueue: ReplayDiskQueue = ReplayDiskQueue(),
        sessionIdProvider: @escaping @Sendable () -> String = { SessionManager.shared.peekSessionId() ?? SessionManager.shared.sessionId },
        uptimeProvider: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.environment = environment
        self.wifiOnly = wifiOnly
        self.diskQueue = diskQueue
        self.sessionIdProvider = sessionIdProvider
        self.uptimeProvider = uptimeProvider
        self.dateProvider = dateProvider
        self.sessionStartUptime = uptimeProvider()
        self.sessionStartTime = dateProvider()
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

    private func prepareSessionLocked(_ currentSession: String) {
        if let chunkSession = currentChunkSessionId, chunkSession != currentSession {
            if !screenFrameBuffer.isEmpty || !screenTouchBuffer.isEmpty {
                triggerFlushLocked()
            }
        }
        if activeSessionId != currentSession {
            activeSessionId = currentSession
            currentChunkSeq = 0
            sessionStartUptime = uptimeProvider()
            sessionStartTime = dateProvider()
        }
        if currentChunkSessionId == nil {
            currentChunkSessionId = currentSession
        }
    }

    public func appendScreenFrame(_ frame: ScreenFramePayload) {
        lock.withLock {
            guard !isScreenshotDisabled else { return }
            let currentSession = sessionIdProvider()
            prepareSessionLocked(currentSession)

            let frameBytes = frame.data.utf8.count
            if !screenFrameBuffer.isEmpty && (currentBufferBytes + frameBytes > Self.maxChunkBytes) {
                triggerFlushLocked()
            }

            screenFrameBuffer.append(frame)
            currentBufferBytes += frameBytes

            if screenFrameBuffer.count >= 20 || currentBufferBytes >= Self.maxChunkBytes {
                triggerFlushLocked()
            }
        }
    }

    public func appendScreenTouch(_ touch: ScreenTouchPoint) {
        lock.withLock {
            guard !isScreenshotDisabled else { return }
            let currentSession = sessionIdProvider()
            prepareSessionLocked(currentSession)
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

    public func pauseFlushTimer() {
        workerQueue.async { [weak self] in
            self?.flushTimer?.cancel()
            self?.flushTimer = nil
            self?.oneShotFlushTimer?.cancel()
            self?.oneShotFlushTimer = nil
        }
    }

    public func resumeFlushTimer() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self.oneShotFlushTimer?.cancel()
            self.oneShotFlushTimer = nil
            if self.flushTimer == nil {
                self.startFlushTimer()
            }
        }
    }

    public func scheduleOneShotFlush(after seconds: TimeInterval) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self.oneShotFlushTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.workerQueue)
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.lock.withLock {
                    self.triggerFlushLocked()
                }
                self.processPendingUploads(completion: nil)
                self.oneShotFlushTimer = nil
            }
            timer.resume()
            self.oneShotFlushTimer = timer
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

        let chunkSession = currentChunkSessionId ?? sessionIdProvider()
        currentChunkSessionId = nil

        let nowUptime = uptimeProvider()
        let durationMs = max(100.0, (nowUptime - sessionStartUptime) * 1000.0)
        let sTime = ISO8601DateFormatter().string(from: sessionStartTime)
        let chunkHasErr = hasError
        let chunkHasRage = hasRageClick

        let framesToUpload = screenFrameBuffer
        let touchesToUpload = screenTouchBuffer
        screenFrameBuffer.removeAll(keepingCapacity: true)
        screenTouchBuffer.removeAll(keepingCapacity: true)
        currentBufferBytes = 0

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
                data: gzipped,
                sessionId: chunkSession
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
                guard !self.isScreenshotDisabled else { return nil }
                guard self.uptimeProvider() >= self.retryNotBeforeUptime else { return nil }
                guard !self.isFlushing else { return nil }
                guard let nextItem = self.diskQueue.peekNext() else { return nil }
                self.isFlushing = true
                return nextItem
            }

            guard let queueItem = item else {
                completion?()
                return
            }

            let sessionId = queueItem.sessionId ?? self.sessionIdProvider()
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
                        self.lock.withLock {
                            self.isScreenshotDisabled = true
                            self.screenFrameBuffer.removeAll(keepingCapacity: false)
                            self.screenTouchBuffer.removeAll(keepingCapacity: false)
                            self.currentBufferBytes = 0
                        }
                        self.pauseFlushTimer()
                        self.diskQueue.clearScreenshotChunks()
                        self.onScreenshotDisabled?()
                    } else if case ReplayUploadError.httpError(_, _, let retryAfter) = error {
                        if let retry = retryAfter, retry > 0 {
                            self.lock.withLock {
                                self.retryNotBeforeUptime = self.uptimeProvider() + retry
                            }
                        }
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
