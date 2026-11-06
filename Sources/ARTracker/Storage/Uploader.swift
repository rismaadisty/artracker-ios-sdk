import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class Uploader: @unchecked Sendable {
    private let lock = UnfairLock()
    private let endpoint: URL
    private let appKey: String
    private let config: ARTrackerConfig
    private let queue: DiskQueue
    private let session: URLSession
    private let backoff = BackoffStrategy()
    private var isUploading: Bool = false
    private var isDisabled: Bool = false
    private var timer: DispatchSourceTimer?
    private let workQueue = DispatchQueue(label: "id.art.tracker.uploader", qos: .utility)

    public init(
        endpoint: URL,
        appKey: String,
        config: ARTrackerConfig,
        queue: DiskQueue
    ) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.config = config
        self.queue = queue

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = sessionConfig.protocolClasses?.filter { $0 != ARTrackerURLProtocol.self }
        sessionConfig.allowsExpensiveNetworkAccess = !config.wifiOnly
        sessionConfig.isDiscretionary = config.wifiOnly
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: sessionConfig)
    }

    deinit {
        stopTimer()
    }

    public func start() {
        startTimer()
        flush()
    }

    public func stop() {
        stopTimer()
    }

    public func disable() {
        lock.withLock {
            isDisabled = true
            stopTimer()
        }
    }

    public func flush(completion: (@Sendable () -> Void)? = nil) {
        workQueue.async { [weak self] in
            self?.performUpload(completion: completion)
        }
    }

    private func startTimer() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: workQueue)
            t.schedule(
                deadline: .now() + config.flushInterval,
                repeating: config.flushInterval,
                leeway: .seconds(2)
            )
            t.setEventHandler { [weak self] in
                self?.performUpload(completion: nil)
            }
            t.resume()
            self.timer = t
        }
    }

    public func suspendTimer() {
        lock.withLock {
            timer?.suspend()
        }
    }

    public func resumeTimer() {
        lock.withLock {
            timer?.resume()
        }
    }

    private func stopTimer() {
        lock.withLock {
            if let t = timer {
                t.cancel()
                self.timer = nil
            }
        }
    }

    private func performUpload(completion: (@Sendable () -> Void)?) {
        let shouldProceed: Bool = lock.withLock {
            guard !isDisabled, !isUploading else { return false }
            isUploading = true
            return true
        }
        guard shouldProceed else {
            completion?()
            return
        }

        defer {
            lock.withLock { isUploading = false }
        }

        guard Reachability.shared.canUpload(wifiOnly: config.wifiOnly) else {
            completion?()
            return
        }

        let records = queue.dequeue(limit: config.maxBatchItems)
        guard !records.isEmpty else {
            completion?()
            return
        }

        guard let batch = BatchBuilder.build(records: records, config: config, enableGzip: true) else {
            completion?()
            return
        }

        sendBatch(batch: batch) { [weak self] in
            // If there's more in queue, attempt next batch
            if let self = self, self.queue.count() > 0 {
                self.workQueue.async {
                    self.performUpload(completion: completion)
                }
            } else {
                completion?()
            }
        }
    }

    private func sendBatch(batch: PreparedBatch, onComplete: @escaping @Sendable () -> Void) {
        var ingestURL = endpoint
        if !ingestURL.path.hasSuffix("/api/v1/ingest") {
            ingestURL = ingestURL.appendingPathComponent("api/v1/ingest")
        }

        var request = URLRequest(url: ingestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "X-Artracker-Key")
        request.setValue("artracker-ios/0.1.0", forHTTPHeaderField: "User-Agent")

        if batch.isGzip {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.httpBody = batch.bodyData

        #if canImport(UIKit)
        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "id.art.tracker.upload") {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
        #endif

        let task = session.dataTask(with: request) { [weak self] respData, response, error in
            #if canImport(UIKit)
            defer {
                if backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskId)
                    backgroundTaskId = .invalid
                }
            }
            #endif

            guard let self = self else {
                onComplete()
                return
            }

            if let http = response as? HTTPURLResponse {
                let bodyStr = respData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.handleHTTPResponse(http, responseBody: bodyStr, for: batch)
            } else if error != nil {
                // Network error: mark failed with exponential backoff
                let delay = self.backoff.delay(forAttempt: 1)
                self.queue.markFailed(ids: batch.recordIds, backoffSeconds: delay)
            }
            onComplete()
        }
        task.resume()
    }

    private func handleHTTPResponse(_ http: HTTPURLResponse, responseBody: String, for batch: PreparedBatch) {
        switch http.statusCode {
        case 200...299:
            // Accepted (202): delete rows from queue
            queue.delete(ids: batch.recordIds)
            Metrics.shared.incrementSent(by: batch.itemCount)
            Log.info("Batch uploaded successfully (\(batch.itemCount) items)")

        case 401, 403:
            // Unauthorized / forbidden: auto-disable to prevent spamming
            lock.withLock { isDisabled = true }
            queue.delete(ids: batch.recordIds)
            Metrics.shared.incrementDropped(by: batch.itemCount)
            Log.error("Invalid API Key. ARTracker auto-disabled. (HTTP \(http.statusCode)): \(responseBody)")

        case 413:
            // Payload too large: split batch by marking records with 0 delay so they are processed in smaller limit
            Log.warn("Batch payload too large (413). Backing off records.")
            self.queue.markFailed(ids: batch.recordIds, backoffSeconds: 1.0)

        case 429, 503:
            // Rate limited or service unavailable: respect Retry-After
            let retryAfterStr = http.value(forHTTPHeaderField: "Retry-After")
            let retrySecs = backoff.parseRetryAfter(header: retryAfterStr) ?? backoff.delay(forAttempt: 2)
            queue.markFailed(ids: batch.recordIds, backoffSeconds: retrySecs)
            Log.warn("Rate limited (HTTP \(http.statusCode)). Backing off for \(retrySecs)s: \(responseBody)")

        default:
            // 4xx/5xx: standard exponential backoff
            let delay = backoff.delay(forAttempt: 1)
            queue.markFailed(ids: batch.recordIds, backoffSeconds: delay)
            Log.warn("Server responded with HTTP \(http.statusCode): \(responseBody)")
        }
    }
}

