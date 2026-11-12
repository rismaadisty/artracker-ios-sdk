import XCTest
@testable import ARTracker

private final class SpyFrameSource: FrameSource, @unchecked Sendable {
    var startCalls = 0
    var stopCalls = 0
    var window = FrameWindow(frames: 60, jank: 0, frozen: 0, refreshHz: 120)

    func start() { startCalls += 1 }
    func stop() { stopCalls += 1 }
    func drain() -> FrameWindow { window }
}

final class PerfMonitorTests: XCTestCase {
    func testBatchFlushAtTenAndManualFlushAtNine() {
        final class State: @unchecked Sendable {
            var nowMs: Int64 = 1_700_000_000_000
            var uptimeMs: Double = 1000
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.perf.monitor.batch")

        let probe = ProcessProbe(
            cpuTimeMs: { 100 },
            threadCount: { 4 },
            footprintBytes: { 104_857_600 },
            thermal: { .nominal },
            cores: 4
        )
        let sampler = PerfSampler(
            probe: probe,
            frames: nil,
            nowMs: {
                state.nowMs += 1000
                return state.nowMs
            },
            uptimeMs: {
                state.uptimeMs += 1000
                return state.uptimeMs
            }
        )

        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, cores: 4, refreshHz: 60) },
            sessionId: { "ses_1" },
            userId: { "u_1" },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        for _ in 0..<10 {
            monitor.tick()
        }
        queue.sync {}

        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.items.first?.type, .perf)
        if case .array(let arr) = state.items.first?.attributes["samples"] {
            XCTAssertEqual(arr.count, 10)
        } else {
            XCTFail("Expected samples array")
        }

        for _ in 0..<9 {
            monitor.tick()
        }
        queue.sync {}
        XCTAssertEqual(state.items.count, 1)

        monitor.flush()
        XCTAssertEqual(state.items.count, 2)
        if case .array(let arr) = state.items.last?.attributes["samples"] {
            XCTAssertEqual(arr.count, 9)
        } else {
            XCTFail("Expected samples array on manual flush")
        }
    }

    func testSessionChangeFlushesOldSamplesUnderOldId() {
        final class State: @unchecked Sendable {
            var sessionId: String? = "s1"
            var nowMs: Int64 = 1_700_000_000_000
            var uptimeMs: Double = 1000
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.perf.monitor.session")

        let probe = ProcessProbe(
            cpuTimeMs: { 100 },
            threadCount: { 4 },
            footprintBytes: { 104_857_600 },
            thermal: { .nominal },
            cores: 4
        )
        let sampler = PerfSampler(
            probe: probe,
            frames: nil,
            nowMs: { state.nowMs },
            uptimeMs: { state.uptimeMs }
        )

        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, cores: 4, refreshHz: nil) },
            sessionId: { state.sessionId },
            userId: { nil },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        for _ in 0..<3 {
            monitor.tick()
        }
        queue.sync {}
        XCTAssertTrue(state.items.isEmpty)

        state.sessionId = "s2"
        monitor.tick()
        queue.sync {}

        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.items[0].sessionId, "s1")
        if case .array(let arr) = state.items[0].attributes["samples"] {
            XCTAssertEqual(arr.count, 3)
        } else {
            XCTFail("Expected 3 samples flushed for s1")
        }

        monitor.flush()
        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(state.items[1].sessionId, "s2")
    }

    func testThermalChangeEnqueuesEvent() {
        final class State: @unchecked Sendable {
            var states: [ProcessInfo.ThermalState] = [.nominal, .nominal, .serious]
            var index = 0
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.perf.monitor.thermal")

        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { 1 },
            footprintBytes: { 1_048_576 },
            thermal: {
                let current = state.states[min(state.index, state.states.count - 1)]
                state.index += 1
                return current
            },
            cores: 2
        )
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })

        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, cores: 2, refreshHz: nil) },
            sessionId: { "s1" },
            userId: { "u1" },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        monitor.tick()
        monitor.tick()
        monitor.tick()
        queue.sync {}

        let thermalEvents = state.items.filter { $0.type == .event && $0.name == "perf.thermal_change" }
        XCTAssertEqual(thermalEvents.count, 1)
        XCTAssertEqual(thermalEvents.first?.sessionId, "s1")
        XCTAssertEqual(thermalEvents.first?.userId, "u1")
        XCTAssertEqual(thermalEvents.first?.attributes["from"], .string("nominal"))
        XCTAssertEqual(thermalEvents.first?.attributes["to"], .string("serious"))
    }

    func testNilSessionSkipsBufferingAndStartIsIdempotent() {
        final class State: @unchecked Sendable {
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.perf.monitor.nil")
        let frames = SpyFrameSource()

        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { 1 },
            footprintBytes: { 1_048_576 },
            thermal: { .nominal },
            cores: 2
        )
        let sampler = PerfSampler(probe: probe, frames: frames, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })

        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, cores: 2, refreshHz: nil) },
            sessionId: { nil },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        monitor.tick()
        monitor.flush()
        XCTAssertTrue(state.items.isEmpty)

        monitor.start()
        monitor.start()
        XCTAssertEqual(frames.startCalls, 1)

        monitor.stop()
        monitor.stop()
        XCTAssertEqual(frames.stopCalls, 1)
    }

    func testDeviceObjectHasOsVersionAndStorage() throws {
        final class State: @unchecked Sendable {
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.perf.monitor.device")
        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { 1 },
            footprintBytes: { 1_048_576 },
            thermal: { .nominal },
            ramFreeMb: { 2000 },
            storageFreeMb: { 50_000 },
            net: { "wifi" },
            cores: 6
        )
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })
        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 6144, storageMb: 128_000, osVersion: "26.4", cores: 6, refreshHz: 120) },
            sessionId: { "s1" },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        monitor.tick()
        monitor.flush()

        let item = try XCTUnwrap(state.items.first)
        guard case .object(let dev) = item.attributes["device"] else {
            return XCTFail("Expected device object")
        }
        XCTAssertEqual(dev["ram_mb"], .number(6144))
        XCTAssertEqual(dev["storage_mb"], .number(128_000))
        XCTAssertEqual(dev["os_version"], .string("26.4"))
        XCTAssertEqual(dev["cores"], .number(6))
        XCTAssertEqual(dev["refresh_hz"], .number(120))
    }

    func testEmptyOsVersionIsOmitted() throws {
        final class State: @unchecked Sendable {
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.perf.monitor.emptyos")
        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { 1 },
            footprintBytes: { 1_048_576 },
            thermal: { .nominal },
            ramFreeMb: { nil },
            storageFreeMb: { nil },
            net: { nil },
            cores: 2
        )
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })
        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, storageMb: nil, osVersion: "", cores: 2, refreshHz: nil) },
            sessionId: { "s1" },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        monitor.tick()
        monitor.flush()

        let item = try XCTUnwrap(state.items.first)
        guard case .object(let dev) = item.attributes["device"] else {
            return XCTFail("Expected device object")
        }
        XCTAssertNil(dev["os_version"])
        XCTAssertNil(dev["storage_mb"])
    }
}

