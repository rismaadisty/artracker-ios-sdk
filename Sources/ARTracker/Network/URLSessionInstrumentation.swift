import Foundation

public final class URLSessionInstrumentation: @unchecked Sendable {
    public static let shared = URLSessionInstrumentation()

    private let lock = UnfairLock()
    private var isInstrumented: Bool = false
    private var isSwizzled: Bool = false

    public func enable(endpointURL: URL, instrumentAllSessions: Bool = false) {
        lock.withLock {
            guard !isInstrumented else { return }
            isInstrumented = true
            ARTrackerURLProtocol.endpointHost = endpointURL.host
            URLProtocol.registerClass(ARTrackerURLProtocol.self)

            if instrumentAllSessions && !isSwizzled {
                isSwizzled = true
                swizzleSessionConfigurations()
            }
        }
    }

    public func disable() {
        lock.withLock {
            guard isInstrumented else { return }
            isInstrumented = false
            URLProtocol.unregisterClass(ARTrackerURLProtocol.self)
        }
    }

    public static func instrument(configuration: URLSessionConfiguration) {
        var protocols = configuration.protocolClasses ?? []
        if !protocols.contains(where: { $0 == ARTrackerURLProtocol.self }) {
            protocols.insert(ARTrackerURLProtocol.self, at: 0)
            configuration.protocolClasses = protocols
        }
    }

    private func swizzleSessionConfigurations() {
        guard object_getClass(URLSessionConfiguration.self) != nil else { return }

        // Swizzle defaultSessionConfiguration
        let defaultSel = #selector(getter: URLSessionConfiguration.default)
        let swizzledDefaultSel = #selector(URLSessionConfiguration.artracker_defaultConfiguration)
        if let originalDefault = class_getClassMethod(URLSessionConfiguration.self, defaultSel),
           let swizzledDefault = class_getClassMethod(URLSessionConfiguration.self, swizzledDefaultSel) {
            method_exchangeImplementations(originalDefault, swizzledDefault)
        }

        // Swizzle ephemeralSessionConfiguration
        let ephemeralSel = #selector(getter: URLSessionConfiguration.ephemeral)
        let swizzledEphemeralSel = #selector(URLSessionConfiguration.artracker_ephemeralConfiguration)
        if let originalEphemeral = class_getClassMethod(URLSessionConfiguration.self, ephemeralSel),
           let swizzledEphemeral = class_getClassMethod(URLSessionConfiguration.self, swizzledEphemeralSel) {
            method_exchangeImplementations(originalEphemeral, swizzledEphemeral)
        }
    }
}

extension URLSessionConfiguration {
    @objc class func artracker_defaultConfiguration() -> URLSessionConfiguration {
        let config = artracker_defaultConfiguration()
        URLSessionInstrumentation.instrument(configuration: config)
        return config
    }

    @objc class func artracker_ephemeralConfiguration() -> URLSessionConfiguration {
        let config = artracker_ephemeralConfiguration()
        URLSessionInstrumentation.instrument(configuration: config)
        return config
    }
}
