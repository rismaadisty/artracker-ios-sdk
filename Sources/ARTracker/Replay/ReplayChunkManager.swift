import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages buffering of ScreenFramePayload and ScreenTouchPoint, adaptive rotation (10s full / 5s buffer),
/// Gzip compression, persistent disk queue in Caches, and uploading to backend / R2.
public final class ReplayChunkManager: @unchecked Sendable {
    public static let maxChunkBytes: Int = 2 * 1024 * 1024
    public static let fullWindowSeconds: TimeInterval = 10.0
    public static let bufferWindowSeconds: TimeInterval = 5.0
    public static let followUpSeconds: TimeInterval = 30.0

    private let lock = UnfairLock()
    private let uploader: any ReplayUploading
    private let environment: String
    private let wifiOnly: Bool
    private let diskQueue: ReplayDiskQueue
    private let sessionIdProvider: @Sendable () -> String
    private let userIdProvider: @Sendable () -> String?
    private let workerQueue = DispatchQueue(label: "com.artracker.replay.worker", qos: .utility)

    // Mode & Follow-up State
    private var recordingMode: ReplayRecordingMode = .full
    private var followUpUntilUptime: TimeInterval? = nil
    private var followUpEndTimer: DispatchSourceTimer? = nil
    private let errorPolicy = ErrorTriggerPolicy()

    // Shared monotonic sequence counter
    private var currentChunkSeq: Int = 0

    // Screenshot buffers
    private var screenFrameBuffer: [ScreenFramePayload] = []
    private var screenTouchBuffer: [ScreenTouchPoint] = []
    private var currentBufferBytes: Int = 0
    private var activeSessionId: String? = nil
    private var currentChunkSessionId: String? = nil
    private var currentChunkUserId: String? = nil

    private var firstEventTsMs: Int64? = nil
    private var lastEventTsMs: Int64? = nil

    private let uptimeProvider: @Sendable () -> TimeInterval
    private let dateProvider: @Sendable () -> Date
    private var sessionStartTime: Date
    private var sessionStartUptime: TimeInterval
    private var lastEventUptime: TimeInterval? = nil
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
        userIdProvider: @escaping @Sendable () -> String? = { SessionManager.shared.userId },
        uptimeProvider: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.environment = environment
        self.wifiOnly = wifiOnly
        self.diskQueue = diskQueue
        self.sessionIdProvider = sessionIdProvider
        self.userIdProvider = userIdProvider
        self.uptimeProvider = uptimeProvider
        self.dateProvider = dateProvider
        self.sessionStartUptime = uptimeProvider()
        self.sessionStartTime = dateProvider()
        startFlushTimer()
        processPendingUploads(completion: nil)
    }

    public func setRecordingMode(_ mode: ReplayRecordingMode, sessionId: String) {
        var shouldPromote = false
        var sessionToDrop: String? = nil

        lock.withLock {
            let oldSessionId = activeSessionId ?? sessionIdProvider()
            let oldMode = recordingMode

            if oldSessionId != sessionId || oldMode != mode {
                triggerFlushLocked()
            }

            if oldMode == .buffer && oldSessionId != sessionId {
                sessionToDrop = oldSessionId
            } else if oldMode == .buffer && mode == .full && oldSessionId == sessionId {
                shouldPromote = true
            }

            followUpUntilUptime = nil
            followUpEndTimer?.cancel()
            followUpEndTimer = nil
            recordingMode = mode
            activeSessionId = sessionId
        }

        if let dropId = sessionToDrop {
            diskQueue.dropHeld(sessionId: dropId)
        }
        if shouldPromote {
            _ = diskQueue.promote(sessionId: sessionId)
            processPendingUploads(completion: nil)
        }

        workerQueue.async { [weak self] in
            self?.restartFlushTimer()
        }
    }

    public func discardHeld(sessionId: String) {
        workerQueue.async { [weak self] in
            self?.diskQueue.dropHeld(sessionId: sessionId)
        }
    }

    public func markError() {
        onError()
    }

    public func onError() {
        var admitted = false
        var targetSession = ""

        lock.withLock {
            hasError = true
            let currentSession = currentChunkSessionId ?? activeSessionId ?? sessionIdProvider()
            targetSession = currentSession
            let nowMs = Int64(uptimeProvider() * 1000.0)

            if recordingMode == .buffer {
                if errorPolicy.admit(sessionId: currentSession, nowMs: nowMs) {
                    admitted = true
                    // Flush current buffer with hasError = true
                    triggerFlushLocked()

                    let followUpUntil = uptimeProvider() + Self.followUpSeconds
                    followUpUntilUptime = followUpUntil

                    followUpEndTimer?.cancel()
                    let timer = DispatchSource.makeTimerSource(queue: workerQueue)
                    timer.schedule(deadline: .now() + Self.followUpSeconds)
                    timer.setEventHandler { [weak self] in
                        self?.lock.withLock {
                            self?.followUpUntilUptime = nil
                            self?.triggerFlushLocked()
                        }
                        self?.processPendingUploads(completion: nil)
                        self?.followUpEndTimer = nil
                    }
                    timer.resume()
                    followUpEndTimer = timer
                }
            }
        }

        if admitted {
            _ = diskQueue.promote(sessionId: targetSession)
            lock.withLock {
                if let next = diskQueue.nextSequence(sessionId: targetSession) {
                    currentChunkSeq = next
                }
            }
            processPendingUploads(completion: nil)
        }
    }

    public func markRageClick() {
        lock.withLock {
            self.hasRageClick = true
        }
    }

    public func handlePreviousRunHoldings(previousRunCrashed: Bool, processStartDate: Date) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isScreenshotDisabled {
                self.diskQueue.dropHeldBefore(processStartDate)
                return
            }

            if previousRunCrashed {
                let count = self.diskQueue.promoteHeldBefore(processStartDate)
                if count > 0 {
                    Log.debug("Replay buffer promoted after crash: \(count) chunks")
                    self.processPendingUploads(completion: nil)
                }
            } else {
                _ = self.diskQueue.dropHeldBefore(processStartDate)
            }
        }
    }

    // MARK: - Screenshot Appending

    private func prepareSessionLocked(_ currentSession: String, _ currentUser: String?) {
        let sessionChanged = (currentChunkSessionId != nil && currentChunkSessionId != currentSession)
        let userChanged = (currentChunkUserId != currentUser && (!screenFrameBuffer.isEmpty || !screenTouchBuffer.isEmpty))
        if sessionChanged || userChanged {
            triggerFlushLocked(overrideEndUptime: lastEventUptime)
        }
        if activeSessionId != currentSession {
            let isInitialBinding = (activeSessionId == nil && lastEventUptime == nil)
            activeSessionId = currentSession
            currentChunkSeq = 0
            if !isInitialBinding {
                sessionStartUptime = uptimeProvider()
                sessionStartTime = dateProvider()
            }
            lastEventUptime = nil
            firstEventTsMs = nil
            lastEventTsMs = nil
        }
        if currentChunkSessionId == nil {
            currentChunkSessionId = currentSession
        }
        if currentChunkUserId == nil {
            currentChunkUserId = currentUser
        }
    }

    public func appendScreenFrame(_ frame: ScreenFramePayload) {
        lock.withLock {
            guard !isScreenshotDisabled else { return }
            let currentSession = sessionIdProvider()
            let currentUser = userIdProvider()
            prepareSessionLocked(currentSession, currentUser)
            lastEventUptime = uptimeProvider()

            if firstEventTsMs == nil {
                firstEventTsMs = frame.ts
            }
            lastEventTsMs = frame.ts

            let frameBytes = frame.data.utf8.count
            if !screenFrameBuffer.isEmpty && (currentBufferBytes + frameBytes > Self.maxChunkBytes) {
                triggerFlushLocked()
                firstEventTsMs = frame.ts
                lastEventTsMs = frame.ts
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
            let currentUser = userIdProvider()
            prepareSessionLocked(currentSession, currentUser)
            lastEventUptime = uptimeProvider()

            if firstEventTsMs == nil {
                firstEventTsMs = touch.ts
            }
            lastEventTsMs = touch.ts

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

    public func handleDidEnterBackground(completion: (@Sendable () -> Void)? = nil) {
        workerQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            self.pauseFlushTimer()
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

    private func restartFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
        startFlushTimer()
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
        let interval = lock.withLock {
            recordingMode == .buffer ? Self.bufferWindowSeconds : Self.fullWindowSeconds
        }
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.lock.withLock {
                self?.triggerFlushLocked()
            }
            self?.processPendingUploads(completion: nil)
        }
        timer.resume()
        self.flushTimer = timer
    }

    private func isCurrentChunkHeldLocked(nowUptime: TimeInterval) -> Bool {
        guard recordingMode == .buffer else { return false }
        if let until = followUpUntilUptime {
            if nowUptime < until {
                return false
            } else {
                followUpUntilUptime = nil
                return true
            }
        }
        return true
    }

    private func triggerFlushLocked(overrideEndUptime: TimeInterval? = nil) {
        guard !screenFrameBuffer.isEmpty || !screenTouchBuffer.isEmpty else { return }

        let chunkSession = currentChunkSessionId ?? sessionIdProvider()
        let chunkUser = currentChunkUserId ?? userIdProvider()
        currentChunkSessionId = nil
        currentChunkUserId = nil

        let nowUptime = uptimeProvider()
        let effectiveEndUptime: TimeInterval
        if let override = overrideEndUptime {
            effectiveEndUptime = override
        } else if let last = lastEventUptime {
            effectiveEndUptime = min(nowUptime, last + SessionManager.shared.idleTimeout)
        } else {
            effectiveEndUptime = nowUptime
        }
        let durationMs = max(100.0, (effectiveEndUptime - sessionStartUptime) * 1000.0)
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

        let held = isCurrentChunkHeldLocked(nowUptime: nowUptime)
        let seq = held ? -1 : currentChunkSeq
        if !held {
            currentChunkSeq += 1
        }

        let firstTs = firstEventTsMs ?? Int64(sessionStartTime.timeIntervalSince1970 * 1000.0)
        let lastTs = lastEventTsMs ?? Int64(dateProvider().timeIntervalSince1970 * 1000.0)
        firstEventTsMs = nil
        lastEventTsMs = nil

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
                sessionId: chunkSession,
                userId: chunkUser,
                held: held,
                firstTsMs: firstTs,
                lastTsMs: lastTs
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
            let userId = queueItem.userId

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
        followUpEndTimer?.cancel()
        oneShotFlushTimer?.cancel()
    }
}
