import Foundation

enum PerfMath {
    static func cpuPercent(prevCpuMs: Double, nowCpuMs: Double, elapsedMs: Double, cores: Int) -> Double? {
        guard elapsedMs > 0, cores > 0 else { return nil }
        let deltaCpu = max(0.0, nowCpuMs - prevCpuMs)
        let raw = (deltaCpu / (elapsedMs * Double(cores))) * 100.0
        return min(100.0, max(0.0, raw))
    }

    static func thermalString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

