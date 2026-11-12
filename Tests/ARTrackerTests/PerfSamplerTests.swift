import XCTest
@testable import ARTracker

private final class FakeFrameSource: FrameSource, @unchecked Sendable {
    var windowToReturn = FrameWindow(frames: 0, jank: 0, frozen: 0, refreshHz: 0)
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func drain() -> FrameWindow {
        windowToReturn
    }
}

final class PerfSamplerTests: XCTestCase {
    func testCpuBaselineAndSecondSampleCalculation() {
        final class State: @unchecked Sendable {
            var cpuMs: Double = 0
            var uptimeMs: Double = 10_000
            var nowMs: Int64 = 1_700_000_000_000
        }
        let state = State()
        let probe = ProcessProbe(
            cpuTimeMs: { state.cpuMs },
            threadCount: { 8 },
            footprintBytes: { 209_715_200 },
            thermal: { .nominal },
            cores: 2
        )
        let frames = FakeFrameSource()
        frames.windowToReturn = FrameWindow(frames: 60, jank: 1, frozen: 0, refreshHz: 120)

        let sampler = PerfSampler(
            probe: probe,
            frames: frames,
            nowMs: { state.nowMs },
            uptimeMs: { state.uptimeMs }
        )

        let first = sampler.sample()
        XCTAssertNil(first.cpu)
        XCTAssertNil(first.fps)
        XCTAssertEqual(first.memMb, 200.0)
        XCTAssertEqual(sampler.lastRefreshHz, 120.0)

        state.cpuMs = 500
        state.uptimeMs = 11_000
        state.nowMs += 1000

        let second = sampler.sample()
        XCTAssertEqual(second.cpu, 25.0)
        XCTAssertEqual(second.fps, 60.0)
        XCTAssertEqual(second.jank, 1)
        XCTAssertEqual(second.frozen, 0)
        XCTAssertEqual(second.threads, 8)
        XCTAssertEqual(second.thermal, "nominal")
    }

    func testNilProbeValuesAndToJSONOmitsNilAndBattery() throws {
        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { nil },
            footprintBytes: { nil },
            thermal: { .fair },
            cores: 4
        )
        let sampler = PerfSampler(
            probe: probe,
            frames: nil,
            nowMs: { 1_700_000_000_123 },
            uptimeMs: { 5000 }
        )

        let sample = sampler.sample()
        XCTAssertNil(sample.threads)
        XCTAssertNil(sample.memMb)
        XCTAssertNil(sample.fps)
        XCTAssertNil(sample.jank)
        XCTAssertNil(sample.frozen)
        XCTAssertEqual(sample.t, 1_700_000_000_123)

        let fullSample = PerfSample(
            t: 1_700_000_000_123,
            cpu: 12.34,
            memMb: 200.0,
            fps: 59.96,
            jank: nil,
            frozen: nil,
            threads: 10,
            thermal: "nominal"
        )
        let data = try JSONEncoder().encode(fullSample.toJSON())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mem_mb"] as? Double, 200.0)
        XCTAssertEqual(dict["cpu"] as? Double, 12.3)
        XCTAssertEqual(dict["fps"] as? Double, 60.0)
        XCTAssertNil(dict["battery"])
        XCTAssertNil(dict["jank"])
        XCTAssertNil(dict["frozen"])
        XCTAssertFalse(dict.values.contains { $0 is NSNull })
    }

    func testSampleCarriesRamStorageAndNet() throws {
        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { 4 },
            footprintBytes: { 104_857_600 },
            thermal: { .nominal },
            ramFreeMb: { 2310 },
            storageFreeMb: { 51_200 },
            net: { "wifi" },
            cores: 4
        )
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })
        let sample = sampler.sample()

        XCTAssertEqual(sample.ramFreeMb, 2310)
        XCTAssertEqual(sample.storageFreeMb, 51_200)
        XCTAssertEqual(sample.net, "wifi")

        let data = try JSONEncoder().encode(sample.toJSON())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["ram_free_mb"] as? Int, 2310)
        XCTAssertEqual(dict["storage_free_mb"] as? Int, 51_200)
        XCTAssertEqual(dict["net"] as? String, "wifi")
    }

    func testFailedVmStatisticsOmitsRamFree() {
        let probe = ProcessProbe.with(freeRamBytesSample: { nil })
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })
        let sample = sampler.sample()

        XCTAssertNil(sample.ramFreeMb)
        XCTAssertNotNil(sample.storageFreeMb)
    }

    func testNilReadingsAreOmitted() throws {
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
        let sample = sampler.sample()

        let data = try JSONEncoder().encode(sample.toJSON())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(dict["ram_free_mb"])
        XCTAssertNil(dict["storage_free_mb"])
        XCTAssertNil(dict["net"])
    }
}

