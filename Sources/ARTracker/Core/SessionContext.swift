import Foundation
import Darwin

public enum SessionContext {
    public static func startAttributes(
        config: ARTrackerConfig? = nil,
        launchType: String? = nil,
        sessionId: String
    ) -> [String: JSONValue] {
        var attrs: [String: JSONValue] = [
            "platform": .string("ios"),
            "manufacturer": .string("Apple"),
            "os_version": .string(osVersionString()),
            "model": .string(deviceModelIdentifier()),
            "app_version": .string(appVersion(config: config)),
            "app_build": .string(appBuild()),
            "locale": .string(bcp47Locale()),
            "tz": .string(TimeZone.current.identifier),
            "network": .string(Reachability.shared.interfaceKind ?? "unknown"),
            "is_emulator": .bool(isEmulator()),
            "sdk_version": .string(SDKInfo.current.version),
            "session_id": .string(sessionId)
        ]

        if let launch = launchType {
            attrs["launch_type"] = .string(launch)
        }

        return attrs
    }

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        } else {
            return "\(v.majorVersion).\(v.minorVersion)"
        }
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

    private static func appVersion(config: ARTrackerConfig?) -> String {
        if let explicit = config?.appVersion, !explicit.isEmpty {
            return explicit
        }
        if let info = Bundle.main.infoDictionary,
           let ver = info["CFBundleShortVersionString"] as? String,
           !ver.isEmpty {
            return ver
        }
        return "1.0.0"
    }

    private static func appBuild() -> String {
        if let info = Bundle.main.infoDictionary,
           let build = info["CFBundleVersion"] as? String,
           !build.isEmpty {
            return build
        }
        return "1"
    }

    private static func bcp47Locale() -> String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    private static func isEmulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
