import Foundation

struct ProcessProbe: Sendable {
    var cpuTimeMs: @Sendable () -> Double = { Metrics.currentProcessCPUTimeMs() }
    var threadCount: @Sendable () -> Int? = { Metrics.currentThreadCount() }
    var footprintBytes: @Sendable () -> UInt64? = { Metrics.physFootprintBytes() }
    var thermal: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    var ramFreeMb: @Sendable () -> Int? = { DeviceFacts.freeRamMb(sample: Metrics.freeRamBytesSample()) }
    var storageFreeMb: @Sendable () -> Int? = { DeviceFacts.storageMb(bytes: Metrics.storageCapacities().freeBytes) }
    var net: @Sendable () -> String? = { Reachability.shared.interfaceKind }
    var cores: Int = ProcessInfo.processInfo.activeProcessorCount

    static func with(
        freeRamBytesSample: @escaping @Sendable () -> (free: UInt64, inactive: UInt64, speculative: UInt64, pageSize: UInt64)?
    ) -> ProcessProbe {
        ProcessProbe(
            ramFreeMb: { DeviceFacts.freeRamMb(sample: freeRamBytesSample()) }
        )
    }
}

final class PerfSampler: @unchecked Sendable {
    private let lock = UnfairLock()
    private let probe: ProcessProbe
    private let frames: FrameSource?
    private let nowMs: @Sendable () -> Int64
    private let uptimeMs: @Sendable () -> Double

    private var prevCpuMs: Double?
    private var prevUptimeMs: Double?
    private var _lastRefreshHz: Double?

    var lastRefreshHz: Double? {
        lock.withLock { _lastRefreshHz }
    }

    func startFrames() {
        frames?.start()
    }

    func stopFrames() {
        frames?.stop()
    }

    init(
        probe: ProcessProbe = ProcessProbe(),
        frames: FrameSource?,
        nowMs: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000.0).rounded()) },
        uptimeMs: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1000.0 }
    ) {
        self.probe = probe
        self.frames = frames
        self.nowMs = nowMs
        self.uptimeMs = uptimeMs
    }

    func sample() -> PerfSample {
        let t = nowMs()
        let currentUptimeMs = uptimeMs()
        let currentCpuMs = probe.cpuTimeMs()
        let threads = probe.threadCount()
        let memMb = probe.footprintBytes().map { Double($0) / 1_048_576.0 }
        let thermal = PerfMath.thermalString(probe.thermal())
        let ramFreeMb = probe.ramFreeMb()
        let storageFreeMb = probe.storageFreeMb()
        let net = probe.net()

        let (elapsedMs, cpuPercent): (Double?, Double?) = lock.withLock {
            defer {
                prevCpuMs = currentCpuMs
                prevUptimeMs = currentUptimeMs
            }
            guard let prevCpu = prevCpuMs, let prevUp = prevUptimeMs else {
                return (nil, nil)
            }
            let elapsed = currentUptimeMs - prevUp
            let cpu = PerfMath.cpuPercent(
                prevCpuMs: prevCpu,
                nowCpuMs: currentCpuMs,
                elapsedMs: elapsed,
                cores: probe.cores
            )
            return (elapsed > 0 ? elapsed : nil, cpu)
        }

        let fps: Double?
        let jank: Int?
        let frozen: Int?

        if let frames = frames {
            let window = frames.drain()
            if window.refreshHz > 0 {
                lock.withLock { _lastRefreshHz = window.refreshHz }
            }
            fps = elapsedMs.flatMap { window.fps(elapsedMs: $0) }
            jank = window.jank
            frozen = window.frozen
        } else {
            fps = nil
            jank = nil
            frozen = nil
        }

        return PerfSample(
            t: t,
            cpu: cpuPercent,
            memMb: memMb,
            fps: fps,
            jank: jank,
            frozen: frozen,
            threads: threads,
            thermal: thermal,
            ramFreeMb: ramFreeMb,
            storageFreeMb: storageFreeMb,
            net: net
        )
    }
}
