import XCTest
import ARTrackerNative
import Darwin

private final class TestThreadState {
    var running: Bool = true
    var counter: Int = 0
}

@inline(never)
private func artnTestSpin(state: TestThreadState) {
    var x: UInt64 = 1
    while state.running {
        state.counter &+= 1
        var i = 0
        while i < 10_000 {
            x = x &* 6364136223846793005 &+ 1
            i &+= 1
        }
    }
    if !state.running {
        _ = x
    }
}

@inline(never)
private func artnTestRecurse(depth: Int, state: TestThreadState) {
    if depth <= 0 {
        artnTestSpin(state: state)
    } else {
        artnTestRecurse(depth: depth - 1, state: state)
    }
}

final class StartupSamplerNativeTests: XCTestCase {
    func testNextIntervalDoublesOnlyWhenSlowAfterTenSamples() {
        XCTAssertEqual(artn_next_interval_us(10_000, 1_500_000, 9), 10_000)
        XCTAssertEqual(artn_next_interval_us(10_000, 1_500_000, 10), 20_000)
        XCTAssertEqual(artn_next_interval_us(20_000, 1_500_000, 11), 20_000)
        XCTAssertEqual(artn_next_interval_us(20_000, 1_500_000, 20), 40_000)
        XCTAssertEqual(artn_next_interval_us(40_000, 9_000_000, 50), 40_000)
        XCTAssertEqual(artn_next_interval_us(10_000, 400_000, 50), 10_000)
    }

    func testCapturesKnownFunctionOnBusyThread() {
        let state = TestThreadState()
        var thread: pthread_t?

        let threadBlock: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { arg in
            let unmanaged = Unmanaged<TestThreadState>.fromOpaque(arg)
            let s = unmanaged.takeRetainedValue()
            artnTestSpin(state: s)
            return nil
        }

        let retainedArg = Unmanaged.passRetained(state).toOpaque()
        pthread_create(&thread, nil, threadBlock, retainedArg)
        guard let pThread = thread else {
            XCTFail("Failed to create worker thread")
            return
        }
        let targetMach = pthread_mach_thread_np(pThread)

        let cfg = artn_sampler_config(max_samples: 100, max_depth: 64, interval_us: 10_000, max_duration_ms: 1000)
        guard let sampler = artn_sampler_create(targetMach, cfg) else {
            XCTFail("Failed to create sampler")
            state.running = false
            pthread_join(pThread, nil)
            return
        }

        XCTAssertTrue(artn_sampler_start(sampler))
        usleep(300_000) // 300 ms
        artn_sampler_request_stop(sampler)
        artn_sampler_join(sampler)

        state.running = false
        pthread_join(pThread, nil)

        let count = artn_sampler_count(sampler)
        XCTAssertGreaterThanOrEqual(count, 10)

        var spinHits = 0
        for i in 0..<count {
            let depth = artn_sampler_depth(sampler, i)
            guard let frames = artn_sampler_frames(sampler, i) else { continue }
            for d in 0..<Int(depth) {
                var dlinfo = Dl_info()
                if dladdr(UnsafeRawPointer(bitPattern: frames[d]), &dlinfo) != 0,
                   let sname = dlinfo.dli_sname {
                    let name = String(cString: sname)
                    if name.contains("artnTestSpin") {
                        spinHits += 1
                        break
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(spinHits) / Double(count), 0.5)
        artn_sampler_destroy(sampler)
    }

    func testDepthCappedKeepsLeafFrames() {
        let state = TestThreadState()
        var thread: pthread_t?

        let threadBlock: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { arg in
            let unmanaged = Unmanaged<TestThreadState>.fromOpaque(arg)
            let s = unmanaged.takeRetainedValue()
            artnTestRecurse(depth: 300, state: s)
            return nil
        }

        let retainedArg = Unmanaged.passRetained(state).toOpaque()
        pthread_create(&thread, nil, threadBlock, retainedArg)
        guard let pThread = thread else {
            XCTFail("Failed to create worker thread")
            return
        }
        let targetMach = pthread_mach_thread_np(pThread)

        let cfg = artn_sampler_config(max_samples: 20, max_depth: 128, interval_us: 10_000, max_duration_ms: 1000)
        guard let sampler = artn_sampler_create(targetMach, cfg) else {
            XCTFail("Failed to create sampler")
            state.running = false
            pthread_join(pThread, nil)
            return
        }

        XCTAssertTrue(artn_sampler_start(sampler))
        usleep(150_000)
        artn_sampler_request_stop(sampler)
        artn_sampler_join(sampler)

        state.running = false
        pthread_join(pThread, nil)

        let count = artn_sampler_count(sampler)
        XCTAssertGreaterThan(count, 0)
        for i in 0..<count {
            let depth = artn_sampler_depth(sampler, i)
            XCTAssertEqual(depth, 128)
            if let frames = artn_sampler_frames(sampler, i) {
                var dlinfo = Dl_info()
                if dladdr(UnsafeRawPointer(bitPattern: frames[0]), &dlinfo) != 0,
                   let sname = dlinfo.dli_sname {
                    let name = String(cString: sname)
                    XCTAssertTrue(name.contains("artnTestSpin") || name.contains("artnTestRecurse"))
                }
            }
        }
        artn_sampler_destroy(sampler)
    }

    func testStopsAtMaxSamples() {
        let state = TestThreadState()
        var thread: pthread_t?

        let threadBlock: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { arg in
            let unmanaged = Unmanaged<TestThreadState>.fromOpaque(arg)
            let s = unmanaged.takeRetainedValue()
            artnTestSpin(state: s)
            return nil
        }

        let retainedArg = Unmanaged.passRetained(state).toOpaque()
        pthread_create(&thread, nil, threadBlock, retainedArg)
        guard let pThread = thread else {
            XCTFail("Failed to create worker thread")
            return
        }
        let targetMach = pthread_mach_thread_np(pThread)

        let cfg = artn_sampler_config(max_samples: 5, max_depth: 32, interval_us: 10_000, max_duration_ms: 5000)
        guard let sampler = artn_sampler_create(targetMach, cfg) else {
            XCTFail("Failed to create sampler")
            state.running = false
            pthread_join(pThread, nil)
            return
        }

        let t0 = artn_now_ns()
        XCTAssertTrue(artn_sampler_start(sampler))
        artn_sampler_join(sampler)
        let elapsedMs = (artn_now_ns() - t0) / 1_000_000
        XCTAssertLessThan(elapsedMs, 1000)
        XCTAssertEqual(artn_sampler_count(sampler), 5)

        state.running = false
        pthread_join(pThread, nil)
        artn_sampler_destroy(sampler)
    }

    func testRequestStopEndsQuickly() {
        let state = TestThreadState()
        var thread: pthread_t?

        let threadBlock: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { arg in
            let unmanaged = Unmanaged<TestThreadState>.fromOpaque(arg)
            let s = unmanaged.takeRetainedValue()
            artnTestSpin(state: s)
            return nil
        }

        let retainedArg = Unmanaged.passRetained(state).toOpaque()
        pthread_create(&thread, nil, threadBlock, retainedArg)
        guard let pThread = thread else {
            XCTFail("Failed to create worker thread")
            return
        }
        let targetMach = pthread_mach_thread_np(pThread)

        let cfg = artn_sampler_config(max_samples: 1000, max_depth: 32, interval_us: 10_000, max_duration_ms: 10_000)
        guard let sampler = artn_sampler_create(targetMach, cfg) else {
            XCTFail("Failed to create sampler")
            state.running = false
            pthread_join(pThread, nil)
            return
        }

        XCTAssertTrue(artn_sampler_start(sampler))
        usleep(50_000) // 50 ms
        let t0 = artn_now_ns()
        artn_sampler_request_stop(sampler)
        artn_sampler_join(sampler)
        let elapsedMs = (artn_now_ns() - t0) / 1_000_000
        XCTAssertLessThan(elapsedMs, 100)

        state.running = false
        pthread_join(pThread, nil)
        artn_sampler_destroy(sampler)
    }

    func testTargetThreadKeepsRunningAfterSampling() {
        let state = TestThreadState()
        var thread: pthread_t?

        let threadBlock: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { arg in
            let unmanaged = Unmanaged<TestThreadState>.fromOpaque(arg)
            let s = unmanaged.takeRetainedValue()
            artnTestSpin(state: s)
            return nil
        }

        let retainedArg = Unmanaged.passRetained(state).toOpaque()
        pthread_create(&thread, nil, threadBlock, retainedArg)
        guard let pThread = thread else {
            XCTFail("Failed to create worker thread")
            return
        }
        let targetMach = pthread_mach_thread_np(pThread)

        let cfg = artn_sampler_config(max_samples: 10, max_depth: 32, interval_us: 5_000, max_duration_ms: 1000)
        guard let sampler = artn_sampler_create(targetMach, cfg) else {
            XCTFail("Failed to create sampler")
            state.running = false
            pthread_join(pThread, nil)
            return
        }

        XCTAssertTrue(artn_sampler_start(sampler))
        artn_sampler_join(sampler)

        let val1 = state.counter
        usleep(20_000)
        let val2 = state.counter
        XCTAssertGreaterThan(val2, val1)

        state.running = false
        pthread_join(pThread, nil)
        artn_sampler_destroy(sampler)
    }

    func testTimesAreMonotonicAndWithinRun() {
        let state = TestThreadState()
        var thread: pthread_t?

        let threadBlock: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { arg in
            let unmanaged = Unmanaged<TestThreadState>.fromOpaque(arg)
            let s = unmanaged.takeRetainedValue()
            artnTestSpin(state: s)
            return nil
        }

        let retainedArg = Unmanaged.passRetained(state).toOpaque()
        pthread_create(&thread, nil, threadBlock, retainedArg)
        guard let pThread = thread else {
            XCTFail("Failed to create worker thread")
            return
        }
        let targetMach = pthread_mach_thread_np(pThread)

        let cfg = artn_sampler_config(max_samples: 15, max_depth: 32, interval_us: 5_000, max_duration_ms: 1000)
        guard let sampler = artn_sampler_create(targetMach, cfg) else {
            XCTFail("Failed to create sampler")
            state.running = false
            pthread_join(pThread, nil)
            return
        }

        let startNs = artn_now_ns()
        XCTAssertTrue(artn_sampler_start(sampler))
        artn_sampler_join(sampler)
        let joinNs = artn_now_ns()

        let count = artn_sampler_count(sampler)
        XCTAssertGreaterThanOrEqual(count, 5)

        var lastT: UInt64 = 0
        for i in 0..<count {
            let t = artn_sampler_time_ns(sampler, i)
            XCTAssertGreaterThanOrEqual(t, startNs)
            XCTAssertLessThanOrEqual(t, joinNs)
            if i > 0 {
                XCTAssertGreaterThan(t, lastT)
            }
            lastT = t
        }

        state.running = false
        pthread_join(pThread, nil)
        artn_sampler_destroy(sampler)
    }
}
