import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct AppStartDevice: Sendable {
    public let model: String?
    public let osVersion: String?
    public let ramMb: Int?
    public let cores: Int?

    public init(
        model: String? = nil,
        osVersion: String? = nil,
        ramMb: Int? = nil,
        cores: Int? = nil
    ) {
        self.model = model
        self.osVersion = osVersion
        self.ramMb = ramMb
        self.cores = cores
    }

    public static func current() -> AppStartDevice {
        let model = DeviceContext.deviceModelIdentifier()
        let osVersion = Metrics.osVersion()
        let ramMb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return AppStartDevice(model: model, osVersion: osVersion, ramMb: ramMb, cores: cores)
    }
}

public enum AppStartItem {
    public static func make(
        _ record: AppStartRecord,
        nowNs: UInt64 = ProcessTimes.uptimeNanoseconds(),
        now: Date = Date(),
        sessionId: String? = nil,
        userId: String? = nil,
        build: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
        device: AppStartDevice = AppStartDevice.current()
    ) -> Item {
        let offsetNs = nowNs >= record.anchorNs ? (nowNs - record.anchorNs) : 0
        let anchorDate = now.addingTimeInterval(-Double(offsetNs) / 1_000_000_000.0)
        let timestamp = DefaultClock.shared.format(date: anchorDate)

        var attrs: [String: JSONValue] = [
            "v": .number(1),
            "platform": .string("ios"),
            "start_id": .string(record.startId),
            "type": .string(record.type.rawValue),
            "duration_ms": .number(Double(record.durationMs)),
            "profiled": .bool(record.profiled)
        ]

        if let firstScreen = record.firstScreen {
            attrs["first_screen"] = .string(firstScreen)
        }

        if let build = build {
            attrs["build"] = .string(build)
        }

        let phaseArray: [JSONValue] = record.phases.map { phase in
            .object([
                "name": .string(phase.name),
                "ms": .number(Double(phase.ms))
            ])
        }
        attrs["phases"] = .array(phaseArray)

        var devDict: [String: JSONValue] = [:]
        if let model = device.model {
            devDict["model"] = .string(model)
        }
        if let osVersion = device.osVersion {
            devDict["os_version"] = .string(osVersion)
        }
        if let ramMb = device.ramMb {
            devDict["ram_mb"] = .number(Double(ramMb))
        }
        if let cores = device.cores {
            devDict["cores"] = .number(Double(cores))
        }
        attrs["device"] = .object(devDict)

        return Item(
            type: .perf,
            name: "app_start",
            timestamp: timestamp,
            sessionId: sessionId,
            userId: userId,
            attributes: attrs
        )
    }
}
