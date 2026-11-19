import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct ProfileContext: Codable, Sendable, Equatable {
    public let app_version: String
    public let build: String?
    public let environment: String

    public init(
        app_version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
        build: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
        environment: String = "production"
    ) {
        self.app_version = app_version
        self.build = build
        self.environment = environment
    }
}

public struct ProfileEnvelope: Codable, Sendable {
    public let sdk: SDKInfo
    public let context: ProfileContext
    public let profile: StartupProfile

    public init(sdk: SDKInfo = .current, context: ProfileContext, profile: StartupProfile) {
        self.sdk = sdk
        self.context = context
        self.profile = profile
    }
}

public enum ProfileBodyError: Error, Equatable {
    case tooLarge
}

public enum ProfileBody {
    public static func gzip(_ env: ProfileEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(env)
        let compressed = try Gzip.compress(data: data)
        guard compressed.count <= 1_048_576 else {
            throw ProfileBodyError.tooLarge
        }
        return compressed
    }
}

public final class ProfileUploader: @unchecked Sendable {
    private let endpoint: URL
    private let appKey: String
    private let store: ProfileStore
    private let session: URLSession
    private let canUpload: () -> Bool
    private let queue = DispatchQueue(label: "id.art.tracker.profiles")
    private var isDisabled: Bool = false

    public init(
        endpoint: URL,
        appKey: String,
        store: ProfileStore,
        session: URLSession = .shared,
        canUpload: @escaping () -> Bool = { Reachability.shared.canUpload(wifiOnly: false) }
    ) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.store = store
        self.session = session
        self.canUpload = canUpload
    }

    public func disable() {
        queue.async {
            self.isDisabled = true
        }
    }

    public func flush(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            if self.isDisabled || !self.canUpload() {
                completion?()
                return
            }

            let pending = self.store.pending()
            guard !pending.isEmpty else {
                completion?()
                return
            }

            self.uploadSequentially(items: pending, index: 0, completion: completion)
        }
    }

    private func uploadSequentially(
        items: [PendingProfile],
        index: Int,
        completion: (@Sendable () -> Void)?
    ) {
        guard index < items.count, !self.isDisabled, self.canUpload() else {
            completion?()
            return
        }

        let p = items[index]
        guard let data = try? Data(contentsOf: p.url) else {
            self.store.delete(p)
            self.uploadSequentially(items: items, index: index + 1, completion: completion)
            return
        }

        let url = endpoint.appendingPathComponent("api/v1/app-start/profiles")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(appKey, forHTTPHeaderField: "X-Artracker-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue("\(SDKInfo.current.name)/\(SDKInfo.current.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = data

        #if canImport(UIKit)
        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "id.art.tracker.profiles.upload") {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
        #endif

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            #if canImport(UIKit)
            defer {
                if backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskId)
                    backgroundTaskId = .invalid
                }
            }
            #endif

            guard let self = self else {
                completion?()
                return
            }

            self.queue.async {
                if error != nil {
                    self.store.markFailed(p)
                    completion?()
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    self.store.markFailed(p)
                    completion?()
                    return
                }

                switch http.statusCode {
                case 200..<300:
                    self.store.delete(p)
                    self.uploadSequentially(items: items, index: index + 1, completion: completion)
                case 413:
                    self.store.delete(p)
                    self.uploadSequentially(items: items, index: index + 1, completion: completion)
                case 401, 403:
                    self.isDisabled = true
                    self.store.delete(p)
                    completion?()
                default:
                    self.store.markFailed(p)
                    completion?()
                }
            }
        }
        task.resume()
    }
}
