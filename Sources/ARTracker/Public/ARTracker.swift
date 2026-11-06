import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class ARTracker: @unchecked Sendable {
    public static let shared = ARTracker()

    private let lock = UnfairLock()
    private var _isInstalled: Bool = false
    private var _config: ARTrackerConfig?
    private var _endpoint: URL?
    private var _appKey: String?
    private var _crashEngine: CrashEngine?
    private var _diskQueue: DiskQueue?
    private var _uploader: Uploader?
    private var sessionStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    public static var isInstalled: Bool {
        shared.lock.withLock { shared._isInstalled }
    }

    public static func configure(
        endpoint: String,
        appKey: String,
        config: ARTrackerConfig = ARTrackerConfig(),
        crashEngine: CrashEngine = PLCrashReporterEngine()
    ) {
        shared.configurePhaseA(
            endpointString: endpoint,
            appKey: appKey,
            config: config,
            crashEngine: crashEngine
        )
    }

    // MARK: - Fase A (Main Thread, <= 2ms target, non-blocking)
    private func configurePhaseA(
        endpointString: String,
        appKey: String,
        config: ARTrackerConfig,
        crashEngine: CrashEngine
    ) {
        LaunchMetrics.shared.markPhaseAStart()

        let alreadyInstalled: Bool = lock.withLock {
            if _isInstalled { return true }
            _isInstalled = true
            return false
        }
        guard !alreadyInstalled else {
            LaunchMetrics.shared.markPhaseAEnd()
            return
        }

        if config.debugLogging {
            Log.shared.level = .debug
        }

        guard let epURL = URL(string: endpointString) else {
            Log.error("Invalid endpoint URL: \(endpointString)")
            LaunchMetrics.shared.markPhaseAEnd()
            return
        }

        self._config = config
        self._endpoint = epURL
        self._appKey = appKey
        self._crashEngine = crashEngine
        self.sessionStartUptime = ProcessInfo.processInfo.systemUptime

        _ = SessionManager.shared.sessionId

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif

        // Install crash engine (Mach + Signal)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try crashEngine.install()
                Log.info("Crash engine installed successfully.")
            } catch {
                Log.error("Failed to install crash engine: \(error.localizedDescription)")
            }
        }

        LaunchMetrics.shared.markPhaseAEnd()

        // Transition to Fase B after first runloop cycle
        DispatchQueue.main.async {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.configurePhaseB()
            }
        }
    }

    // MARK: - Fase B (Utility Queue, Background)
    private func configurePhaseB() {
        guard let config = self._config,
              let endpoint = self._endpoint,
              let appKey = self._appKey else {
            return
        }

        // 1. Crash Context Store (mmap)
        CrashContextStore.shared.initialize()

        // 2. Disk Queue SQLite WAL
        let queue = DiskQueue()
        self._diskQueue = queue

        // 3. Process Pending Crash Reports (PLCrashReporter)
        processPendingCrashReports(queue: queue)

        // 4. Foreground OOM Detection (GAP-02)
        checkAbnormalTermination(queue: queue, config: config)
        TerminationDetector.shared.markStarted()

        // 5. Reachability & MetricKit (GAP-01)
        Reachability.shared.start()
        MetricKitSubscriber.shared.enable()

        // 6. Network Instrumentation (GAP-05)
        if config.enableNetworkCapture {
            URLSessionInstrumentation.shared.enable(
                endpointURL: endpoint,
                instrumentAllSessions: config.instrumentAllSessions
            )
        }

        // 7. View Tree Swizzle
        #if canImport(UIKit)
        if config.enableViewCapture {
            DispatchQueue.main.async {
                UISwizzle.shared.enable()
            }
        }
        #endif

        // 8. Start Uploader
        let uploader = Uploader(
            endpoint: endpoint,
            appKey: appKey,
            config: config,
            queue: queue
        )
        self._uploader = uploader
        uploader.start()

        // 9. API Key Early Validation (GAP-06)
        validateAPIKey(endpoint: endpoint, appKey: appKey, uploader: uploader)

        // 10. Automatic Session Lifecycle Event (GAP-07)
        let sessionItem = Item(
            type: .session,
            name: "session.start",
            sessionId: SessionManager.shared.sessionId,
            userId: SessionManager.shared.userId,
            attributes: [
                "launch_type": .string("cold"),
                "session_id": .string(SessionManager.shared.sessionId)
            ]
        )
        _ = queue.enqueue(sessionItem)

        Log.info("ARTracker Phase B completed. SDK active.")
    }

    private func checkAbnormalTermination(queue: DiskQueue, config: ARTrackerConfig) {
        guard let engine = _crashEngine, engine.pendingReportCount() == 0 else {
            return
        }

        if TerminationDetector.shared.didAbnormallyTerminateInForeground() {
            let prevContext = CrashContextStore.shared.readPreviousContext()
            let devCtx = DeviceContext.capture(config: config)
            var attrs: [String: JSONValue] = [
                "reason": .string("oom_or_jetsam"),
                "is_fatal": .bool(true),
                "device_info": DeviceContext.buildDeviceInfoAttribute(from: devCtx)
            ]

            if let prev = prevContext {
                let crumbJSONs: [JSONValue] = prev.breadcrumbs.map { c in
                    .object([
                        "type": .string(c.type),
                        "category": .string(c.category),
                        "message": .string(c.message),
                        "timestamp": .string(c.timestamp)
                    ])
                }
                attrs["breadcrumbs"] = .array(crumbJSONs)
            }

            let oomItem = Item(
                type: .log,
                name: "app.abnormal_exit",
                level: .error,
                message: "Application terminated abnormally in foreground (likely OOM / Jetsam)",
                sessionId: prevContext?.sessionId ?? SessionManager.shared.sessionId,
                userId: prevContext?.userId ?? SessionManager.shared.userId,
                attributes: attrs
            )
            _ = queue.enqueue(oomItem)
            Log.warn("Detected previous abnormal foreground termination (OOM). Queued telemetry.")
        }
    }

    private func processPendingCrashReports(queue: DiskQueue) {
        guard let engine = _crashEngine else { return }
        let count = engine.pendingReportCount()
        guard count > 0 else { return }

        do {
            let reports = try engine.readPendingReports()
            let prevContext = CrashContextStore.shared.readPreviousContext()
            let devCtx = _config.map { DeviceContext.capture(config: $0) }
                ?? DeviceContext.capture(config: ARTrackerConfig())

            for rep in reports {
                var attrs: [String: JSONValue] = [
                    "stack_trace": .string(rep.stackTrace),
                    "error_type": .string(rep.errorType),
                    "is_fatal": .bool(rep.isFatal),
                    "thread": .string(rep.thread),
                    "device_info": DeviceContext.buildDeviceInfoAttribute(from: devCtx)
                ]

                if let prev = prevContext {
                    let crumbJSONs: [JSONValue] = prev.breadcrumbs.map { c in
                        .object([
                            "type": .string(c.type),
                            "category": .string(c.category),
                            "message": .string(c.message),
                            "timestamp": .string(c.timestamp)
                        ])
                    }
                    attrs["breadcrumbs"] = .array(crumbJSONs)
                }

                if !rep.binaryImages.isEmpty {
                    let imageJSONs: [JSONValue] = rep.binaryImages.map { img in
                        .object([
                            "uuid": .string(img.uuid),
                            "name": .string(img.name),
                            "load_address": .string(img.loadAddress)
                        ])
                    }
                    attrs["binary_images"] = .array(imageJSONs)
                }

                let crashItem = Item(
                    type: .log,
                    name: "crash",
                    level: .fatal,
                    message: rep.message,
                    timestamp: rep.timestamp,
                    sessionId: prevContext?.sessionId ?? SessionManager.shared.sessionId,
                    userId: prevContext?.userId ?? SessionManager.shared.userId,
                    attributes: attrs
                )

                _ = queue.enqueue(crashItem)
            }

            try engine.purge()
            CrashContextStore.shared.purgePreviousContext()
            Log.info("Processed and purged \(reports.count) pending crash report(s).")
        } catch {
            Log.error("Error processing pending crash reports: \(error.localizedDescription)")
        }
    }

    private func validateAPIKey(endpoint: URL, appKey: String, uploader: Uploader) {
        var validateURL = endpoint
        if !validateURL.path.hasSuffix("/api/v1/sdk/validate") {
            validateURL = validateURL.appendingPathComponent("api/v1/sdk/validate")
        }

        var request = URLRequest(url: validateURL)
        request.httpMethod = "GET"
        request.setValue(appKey, forHTTPHeaderField: "X-Artracker-Key")
        request.timeoutInterval = 10

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = sessionConfig.protocolClasses?.filter { $0 != ARTrackerURLProtocol.self }
        let session = URLSession(configuration: sessionConfig)

        session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    uploader.disable()
                    Log.error("API Key validation failed (HTTP \(http.statusCode)). ARTracker disabled.")
                } else if http.statusCode == 200 {
                    Log.info("API Key validated successfully.")
                }
            }
        }.resume()
    }

    // MARK: - Public Runtime API

    public static func setUser(id: String?) {
        SessionManager.shared.userId = id
        CrashContextStore.shared.recordUserId(id)
    }

    public static func setScreen(_ name: String) {
        #if canImport(UIKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap({ $0.windows })
                    .first(where: { $0.isKeyWindow }) {
                    shared.recordScreenView(name: name, view: window.rootViewController?.view)
                    return
                }
                recordScreenFallback(name: name)
            }
            return
        } else {
            DispatchQueue.main.async {
                setScreen(name)
            }
            return
        }
        #else
        recordScreenFallback(name: name)
        #endif
    }

    private static func recordScreenFallback(name: String) {
        BreadcrumbStore.shared.add(
            Breadcrumb(type: "navigation", category: "ui", message: "screen.view \(name)")
        )

        let item = Item(
            type: .event,
            name: "screen.view",
            sessionId: SessionManager.shared.sessionId,
            userId: SessionManager.shared.userId,
            attributes: [
                "screen": .string(name),
                "presentation": .string("manual")
            ]
        )
        shared.enqueueItem(item)
    }

    public static func breadcrumb(
        _ message: String,
        category: String = "ui",
        type: String = "default"
    ) {
        BreadcrumbStore.shared.add(
            Breadcrumb(type: type, category: category, message: message)
        )
    }

    public static func capture(
        error: Error,
        message: String? = nil,
        attributes: [String: Any]? = nil
    ) {
        var attrs: [String: JSONValue] = [:]
        if let custom = attributes {
            for (k, v) in custom {
                attrs[k] = JSONValue.from(v)
            }
        }
        let nsError = error as NSError
        attrs["domain"] = .string(nsError.domain)
        attrs["code"] = .number(Double(nsError.code))

        // GAP-04: Call Stack symbols
        if attrs["stack_trace"] == nil {
            let symbols = Thread.callStackSymbols.dropFirst(2).prefix(60).joined(separator: "\n")
            attrs["stack_trace"] = .string(symbols)
        }

        // GAP-04: Breadcrumbs
        if attrs["breadcrumbs"] == nil {
            attrs["breadcrumbs"] = BreadcrumbStore.shared.asJSONValue()
        }

        // GAP-04: Device Info
        if attrs["device_info"] == nil, let config = shared._config {
            let devCtx = DeviceContext.capture(config: config)
            attrs["device_info"] = DeviceContext.buildDeviceInfoAttribute(from: devCtx)
        }

        let msg = message ?? error.localizedDescription
        let item = Item(
            type: .log,
            name: "error",
            level: .error,
            message: msg,
            sessionId: SessionManager.shared.sessionId,
            userId: SessionManager.shared.userId,
            attributes: attrs
        )
        shared.enqueueItem(item)
    }

    public static func flush(completion: (@Sendable () -> Void)? = nil) {
        shared._uploader?.flush(completion: completion)
    }

    public static func debugMetrics(completion: @escaping @Sendable (TrackerMetricsSummary) -> Void) {
        let qDepth = shared._diskQueue?.count() ?? 0
        let launchA = LaunchMetrics.shared.phaseAMs
        let summary = Metrics.shared.snapshot(queueDepth: qDepth, launchPhaseAMs: launchA)
        completion(summary)
    }

    public static func handleBackgroundEvents(_ completionHandler: @escaping () -> Void) {
        flush {
            completionHandler()
        }
    }

    public func enqueueItem(_ item: Item) {
        _ = _diskQueue?.enqueue(item)
    }

    #if canImport(UIKit)
    @MainActor
    public func recordScreenView(name: String, view: UIView?) {
        var attrs: [String: JSONValue] = [
            "screen": .string(name),
            "presentation": .string("push")
        ]

        if let v = view, let config = _config, config.enableViewCapture {
            if ViewSnapshotter.shared.shouldCapture(screen: name) {
                let (tree, maskedCount) = ViewSnapshotter.shared.capture(view: v, maskAllText: config.maskAllText)
                attrs["masked_count"] = .number(Double(maskedCount))
                if let treeData = try? JSONEncoder().encode(tree),
                   let jsonVal = try? JSONDecoder().decode(JSONValue.self, from: treeData) {
                    attrs["view_tree"] = jsonVal
                }
            }
        }

        BreadcrumbStore.shared.add(
            Breadcrumb(type: "navigation", category: "ui", message: "screen.view \(name)")
        )

        let item = Item(
            type: .event,
            name: "screen.view",
            sessionId: SessionManager.shared.sessionId,
            userId: SessionManager.shared.userId,
            attributes: attrs
        )
        enqueueItem(item)
    }

    @objc private func handleAppDidBecomeActive() {
        sessionStartUptime = ProcessInfo.processInfo.systemUptime
        SessionManager.shared.touch()
        TerminationDetector.shared.setInForeground(true)
        _uploader?.resumeTimer()
    }

    @objc private func handleAppDidEnterBackground() {
        let durationMs = (ProcessInfo.processInfo.systemUptime - sessionStartUptime) * 1000.0
        let sessionEndItem = Item(
            type: .session,
            name: "session.end",
            sessionId: SessionManager.shared.sessionId,
            userId: SessionManager.shared.userId,
            attributes: [
                "duration_ms": .number(durationMs),
                "session_id": .string(SessionManager.shared.sessionId)
            ]
        )
        enqueueItem(sessionEndItem)

        TerminationDetector.shared.setInForeground(false)
        _uploader?.suspendTimer()
        _uploader?.flush()
    }

    @objc private func handleAppWillTerminate() {
        TerminationDetector.shared.markCleanShutdown()
    }

    @objc private func handleAppMemoryWarning() {
        _uploader?.flush()
    }
    #endif
}
