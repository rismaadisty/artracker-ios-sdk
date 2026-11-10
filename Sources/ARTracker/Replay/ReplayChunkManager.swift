import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages buffering of MobileFramePayload and MobileTouchPoint, 10s rotation,
/// Gzip compression, and uploading to backend / R2.
public final class ReplayChunkManager: @unchecked Sendable {
    private let lock = UnfairLock()
    private let uploader: ReplayUploader
    private let environment: String
    private let workerQueue = DispatchQueue(label: "com.artracker.replay.worker", qos: .utility)

    private var currentChunkSeq: Int = 0
    private var frameBuffer: [MobileFramePayload] = []
    private var touchBuffer: [MobileTouchPoint] = []
    private var chunkStartTime: Date = Date()
    private var chunkStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var hasError: Bool = false
    private var hasRageClick: Bool = false
    private var flushTimer: DispatchSourceTimer?
    private var isFlushing: Bool = false
    private var pendingUploadQueue: [(data: Data, seq: Int, count: Int, duration: Double, hasError: Bool, hasRage: Bool, startTime: String)] = []

    public init(uploader: ReplayUploader, environment: String) {
        self.uploader = uploader
        self.environment = environment
        startFlushTimer()
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

    public func appendFrame(_ frame: MobileFramePayload) {
        lock.withLock {
            frameBuffer.append(frame)
            if frameBuffer.count + touchBuffer.count >= 50 {
                triggerFlushLocked()
            }
        }
    }

    public func appendTouch(_ touch: MobileTouchPoint) {
        lock.withLock {
            touchBuffer.append(touch)
            if frameBuffer.count + touchBuffer.count >= 50 {
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
        guard !frameBuffer.isEmpty || !touchBuffer.isEmpty else { return }

        let framesToUpload = frameBuffer
        let touchesToUpload = touchBuffer
        let seq = currentChunkSeq
        currentChunkSeq += 1

        let nowUptime = ProcessInfo.processInfo.systemUptime
        let durationMs = max(100.0, (nowUptime - chunkStartUptime) * 1000.0)
        let sTime = ISO8601DateFormatter().string(from: chunkStartTime)
        let chunkHasErr = hasError
        let chunkHasRage = hasRageClick

        // Reset buffer and state for next chunk
        frameBuffer.removeAll(keepingCapacity: true)
        touchBuffer.removeAll(keepingCapacity: true)
        chunkStartTime = Date()
        chunkStartUptime = nowUptime
        hasError = false
        hasRageClick = false

        // Package into official artracker-mobile-v1 contract
        let payload = MobileChunkPayload(
            format: "artracker-mobile-v1",
            platform: "ios",
            frames: framesToUpload,
            touches: touchesToUpload
        )

        // Debug dump: Simpan JSON asli uncompressed ke disk untuk inspeksi
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let prettyData = try? prettyEncoder.encode(payload) {
            let bundleId = Bundle.main.bundleIdentifier ?? "app"
            let tmpPath = "/tmp/artracker_replay_\(bundleId).json"
            try? prettyData.write(to: URL(fileURLWithPath: tmpPath))

            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let docPath = docs.appendingPathComponent("last_replay_chunk.json")
                try? prettyData.write(to: docPath)
            }
        }

        if let jsonData = try? JSONEncoder().encode(payload),
           let gzipped = try? Gzip.compress(data: jsonData) {
            let totalEvents = framesToUpload.count + touchesToUpload.count
            pendingUploadQueue.append((
                data: gzipped,
                seq: seq,
                count: totalEvents,
                duration: durationMs,
                hasError: chunkHasErr,
                hasRage: chunkHasRage,
                startTime: sTime
            ))
        }
    }

    private func processPendingUploads(completion: (@Sendable () -> Void)? = nil) {
        workerQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            let itemToUpload: (data: Data, seq: Int, count: Int, duration: Double, hasError: Bool, hasRage: Bool, startTime: String)? = self.lock.withLock {
                guard !self.isFlushing, !self.pendingUploadQueue.isEmpty else { return nil }
                self.isFlushing = true
                return self.pendingUploadQueue.removeFirst()
            }

            guard let item = itemToUpload else {
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
                chunkSeq: item.seq,
                sizeBytes: item.data.count,
                userId: userId,
                environment: self.environment,
                startTime: item.startTime
            ) { [weak self] result in
                guard let self = self else {
                    #if canImport(UIKit)
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                    #endif
                    return
                }

                switch result {
                case .success(let (uploadUrl, _)):
                    self.uploader.uploadGzipData(uploadUrl: uploadUrl, gzipData: item.data) { uploadResult in
                        switch uploadResult {
                        case .success:
                            self.uploader.acknowledgeChunk(
                                sessionId: sessionId,
                                chunkSeq: item.seq,
                                sizeBytes: item.data.count,
                                durationMs: item.duration,
                                eventCount: item.count,
                                hasError: item.hasError,
                                hasRageClick: item.hasRage
                            ) { _ in
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
                case .failure:
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
