import XCTest
@testable import ARTracker
import ARTrackerNative
import os

final class StartupProfilerStressTests: XCTestCase {

    func testSamplerSurvivesTargetHoldingMallocAndLocks() {
        final class TargetState: @unchecked Sendable {
            var isRunning = true
            var counter: Int64 = 0
            var lock = os_unfair_lock()
            let syncQueue = DispatchQueue(label: "test.stress.sync")
        }

        let state = TargetState()
        var targetMachThread: thread_t = 0
        let readySem = DispatchSemaphore(value: 0)

        let targetThread = Thread {
            targetMachThread = mach_thread_self()
            readySem.signal()

            while state.isRunning {
                // 1. Malloc & free random sizes
                let size = Int.random(in: 16...4096)
                if let ptr = malloc(size) {
                    memset(ptr, 0xAA, size)
                    free(ptr)
                }

                // 2. os_unfair_lock
                os_unfair_lock_lock(&state.lock)
                state.counter &+= 1
                os_unfair_lock_unlock(&state.lock)

                // 3. String allocation
                let str = "stress_string_\(state.counter)_\(UUID().uuidString)"
                _ = str.count

                // 4. DispatchQueue.sync
                state.syncQueue.sync {
                    state.counter &+= 1
                }
            }
        }
        targetThread.start()
        readySem.wait()

        // Setup native sampler targeting this thread: interval 1000us (1ms), max 5000, 5000ms duration
        let cfg = artn_sampler_config(
            max_samples: 5000,
            max_depth: 128,
            interval_us: 1000,
            max_duration_ms: 5000
        )
        guard let sampler = artn_sampler_create(targetMachThread, cfg) else {
            XCTFail("Failed to create sampler")
            state.isRunning = false
            return
        }

        let started = artn_sampler_start(sampler)
        XCTAssertTrue(started)

        // Verify target counter increases in every 500ms window for 5s
        var prevCounter: Int64 = 0
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 5.0 {
            Thread.sleep(forTimeInterval: 0.5)
            let current = state.counter
            XCTAssertGreaterThan(current, prevCounter, "Target thread stopped progressing")
            prevCounter = current
        }

        state.isRunning = false

        // Join must return within 6s
        let joinStart = Date()
        artn_sampler_join(sampler)
        let joinElapsed = Date().timeIntervalSince(joinStart)
        XCTAssertLessThan(joinElapsed, 6.0, "Join took too long")

        let count = artn_sampler_count(sampler)
        print("Stress test taken samples: \(count)")
        XCTAssertGreaterThan(count, 1000, "Sampler should have captured at least 1000 samples")

        artn_sampler_destroy(sampler)
    }

    func testMeanSampleCostUnderBudget() {
        final class BusyState: @unchecked Sendable {
            var isRunning = true
            var counter: UInt64 = 0
        }
        let state = BusyState()
        var targetMachThread: thread_t = 0
        let readySem = DispatchSemaphore(value: 0)

        let targetThread = Thread {
            targetMachThread = mach_thread_self()
            readySem.signal()
            while state.isRunning {
                state.counter &+= 1
            }
        }
        targetThread.start()
        readySem.wait()

        let cfg = artn_sampler_config(
            max_samples: 300,
            max_depth: 128,
            interval_us: 10_000,
            max_duration_ms: 4000
        )
        guard let sampler = artn_sampler_create(targetMachThread, cfg) else {
            XCTFail("Failed to create sampler")
            state.isRunning = false
            return
        }

        XCTAssertTrue(artn_sampler_start(sampler))
        artn_sampler_join(sampler)
        state.isRunning = false

        let count = artn_sampler_count(sampler)
        let meanCostNs = artn_sampler_mean_cost_ns(sampler)
        print("Mean Sample Cost: \(meanCostNs) ns across \(count) samples")

        XCTAssertGreaterThan(count, 50)
        XCTAssertLessThanOrEqual(meanCostNs, 1_000_000, "Mean sample cost exceeds 1 ms budget")

        artn_sampler_destroy(sampler)
    }

    func testSamplerStartCostUnder1ms() {
        var durationsMs: [Double] = []
        durationsMs.reserveCapacity(50)

        for _ in 0..<50 {
            let t0 = artn_now_ns()
            guard let sampler = StartupSampler(maxDurationMs: 500) else {
                XCTFail("Failed to create sampler")
                continue
            }
            _ = sampler.start()
            let elapsedMs = Double(artn_now_ns() - t0) / 1_000_000.0
            durationsMs.append(elapsedMs)

            sampler.requestStop()
            _ = sampler.collect()
        }

        durationsMs.sort()
        let p95Index = Int(Double(durationsMs.count) * 0.95)
        let p95 = durationsMs[p95Index]
        print("Sampler Start Benchmark: min=\(String(format: "%.3f", durationsMs.first!))ms median=\(String(format: "%.3f", durationsMs[durationsMs.count / 2]))ms p95=\(String(format: "%.3f", p95))ms max=\(String(format: "%.3f", durationsMs.last!))ms")

        XCTAssertLessThanOrEqual(p95, 1.0, "Sampler start p95 exceeds 1.0 ms budget")
    }

    func testTrackingAddsUnder1msToPhaseA() {
        var durationsMs: [Double] = []
        durationsMs.reserveCapacity(50)

        for _ in 0..<50 {
            let t0 = artn_now_ns()
            let times = ProcessTimes.current()
            let tracker = AppStartTracker(
                processTimes: times,
                onReport: { _ in },
                onColdAbandoned: {}
            )
            tracker.configured(at: artn_now_ns(), context: .foreground, profiled: false)
            let elapsedMs = Double(artn_now_ns() - t0) / 1_000_000.0
            durationsMs.append(elapsedMs)
        }

        durationsMs.sort()
        let p95Index = Int(Double(durationsMs.count) * 0.95)
        let p95 = durationsMs[p95Index]
        print("Tracking Phase A Overhead: min=\(String(format: "%.3f", durationsMs.first!))ms median=\(String(format: "%.3f", durationsMs[durationsMs.count / 2]))ms p95=\(String(format: "%.3f", p95))ms max=\(String(format: "%.3f", durationsMs.last!))ms")

        XCTAssertLessThanOrEqual(p95, 1.0, "AppStartTracker setup p95 exceeds 1.0 ms budget")
    }
}
