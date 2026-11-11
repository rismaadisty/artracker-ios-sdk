import Foundation
#if canImport(UIKit)
import UIKit
#endif

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Remote configuration response for session replay mode and limits.
public struct ReplayRemoteConfig: Codable, Sendable {
    public let screenshotEnabled: Bool
    public let maxFps: Double?

    enum CodingKeys: String, CodingKey {
        case screenshotEnabled = "screenshot_enabled"
        case maxFps = "max_fps"
    }

    public init(screenshotEnabled: Bool, maxFps: Double? = nil) {
        self.screenshotEnabled = screenshotEnabled
        self.maxFps = maxFps
    }
}

/// Errors occurring during replay chunk upload negotiation and delivery.
public enum ReplayUploadError: Error, Sendable, LocalizedError {
    case screenshotDisabled
    case httpError(statusCode: Int, message: String?, retryAfter: TimeInterval?)
    case networkError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .screenshotDisabled:
            return "Screenshot replay is disabled on server"
        case .httpError(let code, let msg, _):
            return "HTTP Error \(code): \(msg ?? "Unknown")"
        case .networkError(let desc):
            return "Network Error: \(desc)"
        case .invalidResponse:
            return "Invalid server response format"
        }
    }
}

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

    /// Fetches server-side replay configuration (e.g. screenshot switch and max fps).
    public func fetchReplayConfig(
        completion: @escaping @Sendable (Result<ReplayRemoteConfig, Error>) -> Void
    ) {
        var url = endpoint
        if !url.path.hasSuffix("/api/v1/replay/config") {
            url = url.appendingPathComponent("api/v1/replay/config")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(appKey, forHTTPHeaderField: "X-Artracker-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(ReplayUploadError.networkError(error.localizedDescription)))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ReplayUploadError.invalidResponse))
                return
            }

            guard (200...299).contains(http.statusCode), let data = data else {
                let msg = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(ReplayUploadError.httpError(statusCode: http.statusCode, message: msg, retryAfter: nil)))
                return
            }

            do {
                let config = try JSONDecoder().decode(ReplayRemoteConfig.self, from: data)
                completion(.success(config))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Step 1: Request presigned chunk upload URL
    public func requestChunkUrl(
        sessionId: String,
        chunkSeq: Int,
        sizeBytes: Int,
        userId: String?,
        environment: String,
        startTime: String,
        format: String = "artracker-mobile-v1",
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
            "start_time": startTime,
            "format": format
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

            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? -1

            if statusCode == 403 {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errStr = json["error"] as? String,
                   errStr == "screenshot_disabled" {
                    completion(.failure(ReplayUploadError.screenshotDisabled))
                    return
                }
            }

            guard let http = http, (200...299).contains(http.statusCode), let data = data else {
                let msg = data.flatMap { String(data: $0, encoding: .utf8) }
                let retryAfterStr = http?.value(forHTTPHeaderField: "Retry-After")
                let retrySeconds = retryAfterStr.flatMap { Double($0) }
                completion(.failure(ReplayUploadError.httpError(statusCode: statusCode, message: msg, retryAfter: retrySeconds)))
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

