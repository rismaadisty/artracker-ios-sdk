import Foundation
import ARTrackerNative

public struct ProcessTimes: Sendable, Equatable {
    public let processStartNs: UInt64?
    public let preMainEndNs: UInt64?

    public static func uptimeNanoseconds() -> UInt64 {
        artn_now_ns()
    }

    public static func current() -> ProcessTimes {
        let ctorUptime = artn_constructor_uptime_ns()
        let ctorWall = artn_constructor_wall_us()
        var procStartWall: Int64 = 0
        let hasProcStart = artn_process_start_wall_us(&procStartWall)
        return from(
            constructorUptimeNs: ctorUptime,
            constructorWallUs: ctorWall,
            processStartWallUs: hasProcStart ? procStartWall : nil
        )
    }

    public static func from(
        constructorUptimeNs: UInt64,
        constructorWallUs: Int64,
        processStartWallUs: Int64?
    ) -> ProcessTimes {
        let preMainEndNs = constructorUptimeNs > 0 ? constructorUptimeNs : nil
        guard let procStartWall = processStartWallUs else {
            return ProcessTimes(processStartNs: nil, preMainEndNs: preMainEndNs)
        }
        let deltaUs = constructorWallUs - procStartWall
        if deltaUs < 0 {
            return ProcessTimes(processStartNs: nil, preMainEndNs: preMainEndNs)
        }
        let deltaNs = UInt64(deltaUs) * 1000
        if deltaNs > constructorUptimeNs {
            return ProcessTimes(processStartNs: nil, preMainEndNs: preMainEndNs)
        }
        let processStartNs = constructorUptimeNs - deltaNs
        return ProcessTimes(processStartNs: processStartNs, preMainEndNs: preMainEndNs)
    }
}
