import Foundation
import ARTrackerNative
import Darwin

public struct RawSample: Sendable, Equatable {
    public let tNs: UInt64
    public let framesLeafFirst: [UInt]

    public init(tNs: UInt64, framesLeafFirst: [UInt]) {
        self.tNs = tNs
        self.framesLeafFirst = framesLeafFirst
    }
}

public struct RawProfile: Sendable, Equatable {
    public let finalIntervalUs: Int
    public let meanCostNs: UInt64
    public let samples: [RawSample]

    public init(finalIntervalUs: Int, meanCostNs: UInt64, samples: [RawSample]) {
        self.finalIntervalUs = finalIntervalUs
        self.meanCostNs = meanCostNs
        self.samples = samples
    }
}

public final class StartupSampler: @unchecked Sendable {
    private let sampler: OpaquePointer
    private var isDestroyed = false

    public init?(
        target: thread_t = artn_main_mach_thread(),
        intervalMs: Int = 10,
        maxSamples: Int = 1000,
        maxDepth: Int = 128,
        maxDurationMs: Int = 10_000
    ) {
        let cfg = artn_sampler_config(
            max_samples: UInt32(max(1, maxSamples)),
            max_depth: UInt32(max(1, maxDepth)),
            interval_us: UInt32(max(1, intervalMs * 1000)),
            max_duration_ms: UInt32(max(1, maxDurationMs))
        )
        guard let s = artn_sampler_create(target, cfg) else {
            return nil
        }
        self.sampler = s
    }

    deinit {
        destroyIfNeeded()
    }

    public func start() -> Bool {
        artn_sampler_start(sampler)
    }

    public func requestStop() {
        artn_sampler_request_stop(sampler)
    }

    public func collect() -> RawProfile {
        artn_sampler_request_stop(sampler)
        artn_sampler_join(sampler)

        let count = artn_sampler_count(sampler)
        var samples: [RawSample] = []
        samples.reserveCapacity(Int(count))

        for i in 0..<count {
            let t = artn_sampler_time_ns(sampler, i)
            let depth = Int(artn_sampler_depth(sampler, i))
            if let framesPtr = artn_sampler_frames(sampler, i) {
                var frames: [UInt] = []
                frames.reserveCapacity(depth)
                for d in 0..<depth {
                    frames.append(UInt(framesPtr[d]))
                }
                samples.append(RawSample(tNs: t, framesLeafFirst: frames))
            } else {
                samples.append(RawSample(tNs: t, framesLeafFirst: []))
            }
        }

        let finalInterval = Int(artn_sampler_final_interval_us(sampler))
        let meanCost = artn_sampler_mean_cost_ns(sampler)

        destroyIfNeeded()

        return RawProfile(
            finalIntervalUs: finalInterval,
            meanCostNs: meanCost,
            samples: samples
        )
    }

    private func destroyIfNeeded() {
        if !isDestroyed {
            isDestroyed = true
            artn_sampler_destroy(sampler)
        }
    }
}
