import Foundation

/// Configuration options for the ARTracker SDK.
public struct ARTrackerConfig: Sendable {
    /// Target environment (e.g., "production", "development", "staging").
    /// Truncated to 64 chars per backend ingest specification.
    public var environment: String

    /// Optional explicit app version string. If nil, inferred from Bundle.main.
    public var appVersion: String?

    /// Automatically capture URLSession network requests. Default: true.
    public var enableNetworkCapture: Bool

    /// Automatically capture screen appearances (UIViewController / SwiftUI). Default: true.
    public var enableViewCapture: Bool

    /// Automatically record session replay wireframe stream. Default: true.
    public var enableSessionReplay: Bool

    /// Mask all text fields in captured view hierarchy. Default: false.
    public var maskAllText: Bool

    /// If true, only uploads when connected to Wi-Fi. Default: false (cellular & Wi-Fi allowed).
    public var wifiOnly: Bool

    /// Maximum breadcrumbs kept in rolling buffer. Default: 50.
    public var maxBreadcrumbs: Int

    /// Maximum items per batch upload. Backend limit is 500, default: 100.
    public var maxBatchItems: Int

    /// Periodic flush interval in seconds. Default: 30.0.
    public var flushInterval: TimeInterval

    /// Event sampling rate from 0.0 to 1.0. Default: 1.0 (100%).
    public var sampleRate: Double

    /// Swizzle URLSession.dataTask for all sessions instead of URLProtocol. Default: false.
    public var instrumentAllSessions: Bool

    /// Enable verbose SDK internal logging for debugging. Default: false.
    public var debugLogging: Bool

    public init(
        environment: String = "production",
        appVersion: String? = nil,
        enableNetworkCapture: Bool = true,
        enableViewCapture: Bool = true,
        enableSessionReplay: Bool = true,
        maskAllText: Bool = false,
        wifiOnly: Bool = false,
        maxBreadcrumbs: Int = 50,
        maxBatchItems: Int = 100,
        flushInterval: TimeInterval = 30.0,
        sampleRate: Double = 1.0,
        instrumentAllSessions: Bool = false,
        debugLogging: Bool = false
    ) {
        self.environment = String(environment.prefix(64))
        self.appVersion = appVersion.map { String($0.prefix(64)) }
        self.enableNetworkCapture = enableNetworkCapture
        self.enableViewCapture = enableViewCapture
        self.enableSessionReplay = enableSessionReplay
        self.maskAllText = maskAllText
        self.wifiOnly = wifiOnly
        self.maxBreadcrumbs = max(10, min(maxBreadcrumbs, 200))
        self.maxBatchItems = max(1, min(maxBatchItems, 500))
        self.flushInterval = max(1.0, flushInterval)
        self.sampleRate = max(0.0, min(sampleRate, 1.0))
        self.instrumentAllSessions = instrumentAllSessions
        self.debugLogging = debugLogging
    }
}

