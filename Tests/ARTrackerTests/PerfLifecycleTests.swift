import XCTest
@testable import ARTracker

final class PerfLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ARTracker.shared._testInstallPerfMonitor(nil, queue: nil)
    }

    override func tearDownWithError() throws {
        ARTracker.shared._testInstallPerfMonitor(nil, queue: nil)
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testDisabledCreatesNothing() {
        let defaultConfig = ARTrackerConfig()
        XCTAssertFalse(defaultConfig.enablePerformanceMonitoring)
        ARTracker.shared.startPerfMonitorIfNeeded(config: defaultConfig)
        XCTAssertNil(ARTracker.shared.perfMonitorForTesting)
    }

    func testBackgroundEnqueuesPerfItemBeforeSessionEnd() throws {
        let dbURL = tempDir.appendingPathComponent("perf-bg.sqlite")
        let queue = DiskQueue(databaseURL: dbURL)
        let workQueue = DispatchQueue(label: "test.lifecycle.bg")

        let probe = ProcessProbe(
            cpuTimeMs: { 100 },
            threadCount: { 5 },
            footprintBytes: { 104_857_600 },
            thermal: { .nominal },
            cores: 4
        )
        let sampler = PerfSampler(
            probe: probe,
            frames: nil,
            nowMs: { 1_700_000_000_000 },
            uptimeMs: { 1000 }
        )
        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, cores: 4, refreshHz: nil) },
            sessionId: { "ses_bg_test" },
            userId: { nil },
            enqueue: { ARTracker.shared.enqueueItem($0) },
            queue: workQueue
        )

        ARTracker.shared._testInstallPerfMonitor(monitor, queue: queue)

        for _ in 0..<4 {
            monitor.tick()
        }
        workQueue.sync {}

        ARTracker.shared.handleAppDidEnterBackground()

        let records = queue.dequeue(limit: 50)
        let perfRecord = try XCTUnwrap(records.first(where: { $0.item.type == .perf }))
        let sessionEndRecord = try XCTUnwrap(records.first(where: { $0.item.type == .session && $0.item.name == "session.end" }))

        if case .array(let arr) = perfRecord.item.attributes["samples"] {
            XCTAssertEqual(arr.count, 4)
        } else {
            XCTFail("Expected 4 samples in flushed perf item")
        }

        XCTAssertLessThan(perfRecord.id, sessionEndRecord.id)
    }

    func testBackgroundStopsTimerSoNoNewSamplesArrive() {
        let dbURL = tempDir.appendingPathComponent("perf-stop.sqlite")
        let queue = DiskQueue(databaseURL: dbURL)
        let workQueue = DispatchQueue(label: "test.lifecycle.stop")

        final class Flag: @unchecked Sendable {
            let lock = UnfairLock()
            var armed = false
            var expectation: XCTestExpectation?
        }
        let flag = Flag()

        let probe = ProcessProbe(
            cpuTimeMs: {
                flag.lock.withLock {
                    if flag.armed {
                        flag.expectation?.fulfill()
                    }
                }
                return 0
            },
            threadCount: { 1 },
            footprintBytes: { 1_048_576 },
            thermal: { .nominal },
            cores: 2
        )
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })
        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 500,
            device: { PerfDevice(ramMb: 4096, cores: 2, refreshHz: nil) },
            sessionId: { "ses_stop_test" },
            enqueue: { ARTracker.shared.enqueueItem($0) },
            queue: workQueue
        )

        ARTracker.shared._testInstallPerfMonitor(monitor, queue: queue)
        monitor.start()
        ARTracker.shared.handleAppDidEnterBackground()

        let noSampleAfterBackground = expectation(description: "No sample sampled after background")
        noSampleAfterBackground.isInverted = true
        flag.lock.withLock {
            flag.expectation = noSampleAfterBackground
            flag.armed = true
        }

        wait(for: [noSampleAfterBackground], timeout: 1.0)
    }

    func testMemoryWarningEnqueuesEventOnlyWhenMonitorInstalled() throws {
        let dbURL1 = tempDir.appendingPathComponent("perf-mem-1.sqlite")
        let queue1 = DiskQueue(databaseURL: dbURL1)
        let workQueue = DispatchQueue(label: "test.lifecycle.mem")

        let probe = ProcessProbe(
            cpuTimeMs: { 0 },
            threadCount: { 1 },
            footprintBytes: { 1_048_576 },
            thermal: { .nominal },
            cores: 2
        )
        let sampler = PerfSampler(probe: probe, frames: nil, nowMs: { 1_700_000_000_000 }, uptimeMs: { 1000 })
        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: { PerfDevice(ramMb: 4096, cores: 2, refreshHz: nil) },
            sessionId: { "ses_mem_test" },
            enqueue: { ARTracker.shared.enqueueItem($0) },
            queue: workQueue
        )

        ARTracker.shared._testInstallPerfMonitor(monitor, queue: queue1)
        ARTracker.shared.handleAppMemoryWarning()

        let records1 = queue1.dequeue(limit: 10)
        XCTAssertEqual(records1.count, 1)
        XCTAssertEqual(records1.first?.item.type, .event)
        XCTAssertEqual(records1.first?.item.name, "perf.memory_warning")
        XCTAssertNotNil(records1.first?.item.sessionId)

        let dbURL2 = tempDir.appendingPathComponent("perf-mem-2.sqlite")
        let queue2 = DiskQueue(databaseURL: dbURL2)
        ARTracker.shared._testInstallPerfMonitor(nil, queue: queue2)
        ARTracker.shared.handleAppMemoryWarning()

        let records2 = queue2.dequeue(limit: 10)
        XCTAssertTrue(records2.isEmpty)
    }
}

