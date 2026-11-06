import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct DeviceContext: Codable, Sendable, Equatable {
    public let environment: String
    public let appVersion: String
    public let osName: String
    public let osVersion: String
    public let deviceModel: String
    public let locale: String
    public let timezone: String

    enum CodingKeys: String, CodingKey {
        case environment
        case appVersion = "app_version"
        case osName = "os_name"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case locale
        case timezone
    }

    public static func capture(config: ARTrackerConfig) -> DeviceContext {
        let appVer = config.appVersion ?? defaultAppVersion()
        let model = deviceModelIdentifier()
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let loc = Locale.current.identifier
        let tz = TimeZone.current.identifier

        return DeviceContext(
            environment: String(config.environment.prefix(64)),
            appVersion: String(appVer.prefix(64)),
            osName: "iOS",
            osVersion: osVer,
            deviceModel: model,
            locale: loc,
            timezone: tz
        )
    }

    /// Builds the `device_info` JSON attribute conforming strictly to backend & UI frontend contracts:
    /// `os`, `browser`, `screen`, `user_agent`, plus metadata (`device_model`, `locale`, `timezone`).
    public static func buildDeviceInfoAttribute(from context: DeviceContext) -> JSONValue {
        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "ARTrackerApp"
        let browser = "\(appName)/\(context.appVersion)"
        let userAgent = "\(appName)/\(context.appVersion) (\(context.deviceModel); \(context.osName) \(context.osVersion))"

        var screenStr = "unknown"
        #if canImport(UIKit)
        if Thread.isMainThread {
            let bounds = UIScreen.main.bounds
            let scale = Int(UIScreen.main.scale)
            screenStr = "\(Int(bounds.width))x\(Int(bounds.height)) @\(scale)x"
        }
        #endif

        return .object([
            "os": .string("\(context.osName) \(context.osVersion)"),
            "browser": .string(browser),
            "screen": .string(screenStr),
            "user_agent": .string(userAgent),
            "device_model": .string(context.deviceModel),
            "locale": .string(context.locale),
            "timezone": .string(context.timezone)
        ])
    }

    private static func defaultAppVersion() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }
}
