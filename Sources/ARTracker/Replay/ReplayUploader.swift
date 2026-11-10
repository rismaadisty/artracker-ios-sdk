import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Network uploader for replay chunks.
/// Uses an isolated ephemeral URLSession that bypasses ARTrackerURLProtocol to prevent infinite loops.
public final class ReplayUploader: @unchecked Sendable {
    private let endpoint: URL
    private let appKey: String
    private let session: URLSession

    public init(endpoint: URL, appKey: String) {
        self.endpoint = endpoint
        self.appKey = appKey

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // Strip out ARTrackerURLProtocol to prevent intercepting own R2 presigned uploads
        config.protocolClasses = config.protocolClasses?.filter { $0 != ARTrackerURLProtocol.self }
        self.session = URLSession(configuration: config)
    }

    /// Step 1: Request presigned chunk upload URL
    public func requestChunkUrl(
        sessionId: String,
        chunkSeq: Int,
        sizeBytes: Int,
        userId: String?,
        environment: String,
        startTime: String,
        completion: @escaping @Sendable (Result<(uploadUrl: URL, objectKey: String), Error>) -> Void
    ) {
        var url = endpoint
        if !url.path.hasSuffix("/api/v1/replay/chunk-url") {
            url = url.appendingPathComponent("api/v1/replay/chunk-url")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(appKey, forHTTPHeaderField: "X-Artracker-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var bodyDict: [String: Any] = [
            "session_id": sessionId,
            "chunk_seq": chunkSeq,
            "size_bytes": sizeBytes,
            "environment": environment,
            "start_time": startTime
        ]
        if let uid = userId {
            bodyDict["user_id"] = uid
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            completion(.failure(NSError(domain: "ARTrackerReplay", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize chunk-url payload"])))
            return
        }
        req.httpBody = bodyData

        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data = data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(domain: "ARTrackerReplay", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed chunk-url request (HTTP \(code))"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   var uploadUrlStr = json["upload_url"] as? String,
                   let objectKey = json["object_key"] as? String {
                    // Auto-upgrade to HTTPS if endpoint uses HTTPS
                    if self.endpoint.scheme == "https" && uploadUrlStr.hasPrefix("http://") {
                        uploadUrlStr = "https://" + uploadUrlStr.dropFirst(7)
                    }
                    if let uploadUrl = URL(string: uploadUrlStr) {
                        completion(.success((uploadUrl, objectKey)))
                    } else {
                        completion(.failure(NSError(domain: "ARTrackerReplay", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid chunk-url response format"])))
                    }
                } else {
                    completion(.failure(NSError(domain: "ARTrackerReplay", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid chunk-url response format"])))
                }
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Step 2: Upload gzipped bytes directly to Object Storage (R2 / S3)
    public func uploadGzipData(
        uploadUrl: URL,
        gzipData: Data,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        var req = URLRequest(url: uploadUrl)
        req.httpMethod = "PUT"
        req.setValue("application/gzip", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: req, from: gzipData) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(domain: "ARTrackerReplay", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed PUT to storage (HTTP \(code))"])))
                return
            }
            completion(.success(()))
        }
        task.resume()
    }

    /// Step 3: Acknowledge chunk completion to backend
    public func acknowledgeChunk(
        sessionId: String,
        chunkSeq: Int,
        sizeBytes: Int,
        durationMs: Double,
        eventCount: Int,
        hasError: Bool,
        hasRageClick: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        var url = endpoint
        if !url.path.hasSuffix("/api/v1/replay/chunk-ack") {
            url = url.appendingPathComponent("api/v1/replay/chunk-ack")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(appKey, forHTTPHeaderField: "X-Artracker-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let durationInt = Int64(durationMs.rounded())
        let bodyDict: [String: Any] = [
            "session_id": sessionId,
            "chunk_seq": chunkSeq,
            "size_bytes": sizeBytes,
            "duration_ms": durationInt,
            "event_count": eventCount,
            "has_error": hasError,
            "has_rage_click": hasRageClick,
            "has_dead_click": false
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            completion(.failure(NSError(domain: "ARTrackerReplay", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize chunk-ack payload"])))
            return
        }
        req.httpBody = bodyData

        let task = session.dataTask(with: req) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(domain: "ARTrackerReplay", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed chunk-ack request (HTTP \(code))"])))
                return
            }
            completion(.success(()))
        }
        task.resume()
    }
}

