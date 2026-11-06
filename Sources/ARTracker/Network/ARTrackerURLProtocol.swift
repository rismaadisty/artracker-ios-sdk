import Foundation

public final class ARTrackerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledKey = "ARTrackerHandledKey"
    public static var endpointHost: String?

    private var activeTask: URLSessionDataTask?
    private var startTime: TimeInterval = 0
    private var responseBytes: Int = 0

    public override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }

        // Ignore already handled requests
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }

        // Ignore ARTracker SDK internal requests
        if request.value(forHTTPHeaderField: "X-Artracker-Key") != nil {
            return false
        }
        if let host = url.host, let endpointHost = endpointHost, host.caseInsensitiveCompare(endpointHost) == .orderedSame {
            return false
        }

        // Only handle HTTP/HTTPS schemes
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }

        return true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotCreateFile))
            return
        }

        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        self.startTime = ProcessInfo.processInfo.systemUptime

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = sessionConfig.protocolClasses?.filter { $0 != ARTrackerURLProtocol.self }
        let session = URLSession(configuration: sessionConfig)
        self.activeTask = session.dataTask(with: mutableRequest as URLRequest) { [weak self] data, response, error in
            guard let self = self else { return }

            let durationMs = Int((ProcessInfo.processInfo.systemUptime - self.startTime) * 1000.0)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? (error != nil ? 0 : 200)

            if let url = self.request.url {
                let info = Redactor.sanitize(url: url)
                let method = self.request.httpMethod ?? "GET"
                let reqBytes = self.request.httpBody?.count ?? 0
                let respBytes = data?.count ?? 0

                // Record Breadcrumb
                let crumbMsg = "\(method) \(info.host)\(info.path) \(statusCode) \(durationMs)ms"
                BreadcrumbStore.shared.add(
                    Breadcrumb(type: "http", category: "network", message: crumbMsg)
                )

                // Enqueue http.request event
                let item = Item(
                    type: .event,
                    name: "http.request",
                    sessionId: SessionManager.shared.sessionId,
                    userId: SessionManager.shared.userId,
                    attributes: [
                        "method": .string(method),
                        "host": .string(info.host),
                        "path": .string(info.path),
                        "status_code": .number(Double(statusCode)),
                        "duration_ms": .number(Double(durationMs)),
                        "request_bytes": .number(Double(reqBytes)),
                        "response_bytes": .number(Double(respBytes)),
                        "error": error != nil ? .string(error!.localizedDescription) : .null,
                        "protocol": .string(httpResponse?.value(forHTTPHeaderField: "Upgrade") ?? "h2")
                    ]
                )
                ARTracker.shared.enqueueItem(item)
            }

            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                if let response = response {
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if let data = data {
                    self.client?.urlProtocol(self, didLoad: data)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        self.activeTask?.resume()
    }

    public override func stopLoading() {
        activeTask?.cancel()
        activeTask = nil
    }
}

