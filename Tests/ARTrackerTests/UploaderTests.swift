import XCTest
@testable import ARTracker

final class UploaderTests: XCTestCase {
    private var tempDir: URL!
    private var dummyEndpoint: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dummyEndpoint = URL(string: "http://127.0.0.1:9")!
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeUploader(name: String = "queue.sqlite") -> Uploader {
        let queue = DiskQueue(databaseURL: tempDir.appendingPathComponent(name))
        let config = ARTrackerConfig(flushInterval: 60.0)
        return Uploader(endpoint: dummyEndpoint, appKey: "art_test_key", config: config, queue: queue)
    }

    func testResumeWithoutSuspendIsNoOp() {
        let uploader = makeUploader()
        uploader.start()
        defer { uploader.stop() }

        uploader.resumeTimer()
        uploader.resumeTimer()
        uploader.resumeTimer()

        XCTAssertTrue(uploader.hasTimerForTesting)
        XCTAssertFalse(uploader.isTimerSuspendedForTesting)
    }

    func testMultipleSuspendAndResumeCyclesAreIdempotent() {
        let uploader = makeUploader()
        uploader.start()
        defer { uploader.stop() }

        uploader.suspendTimer()
        uploader.suspendTimer()
        XCTAssertTrue(uploader.isTimerSuspendedForTesting)

        uploader.resumeTimer()
        uploader.resumeTimer()
        XCTAssertFalse(uploader.isTimerSuspendedForTesting)
    }

    func testStopWhileSuspendedResumesBeforeCancel() {
        let uploader = makeUploader()
        uploader.start()
        uploader.suspendTimer()
        XCTAssertTrue(uploader.isTimerSuspendedForTesting)

        uploader.stop()

        XCTAssertFalse(uploader.hasTimerForTesting)
        XCTAssertFalse(uploader.isTimerSuspendedForTesting)
    }

    func testDisableWhileActiveAndWhileSuspendedDoesNotDeadlock() {
        let activeUploader = makeUploader(name: "active.sqlite")
        activeUploader.start()
        activeUploader.disable()
        XCTAssertTrue(activeUploader.isDisabledForTesting)
        XCTAssertFalse(activeUploader.hasTimerForTesting)

        let suspendedUploader = makeUploader(name: "suspended.sqlite")
        suspendedUploader.start()
        suspendedUploader.suspendTimer()
        suspendedUploader.disable()
        XCTAssertTrue(suspendedUploader.isDisabledForTesting)
        XCTAssertFalse(suspendedUploader.hasTimerForTesting)
        XCTAssertFalse(suspendedUploader.isTimerSuspendedForTesting)
    }

    func testDeinitWhileSuspendedDoesNotCrash() {
        weak var weakUploader: Uploader?
        let queue = DiskQueue(databaseURL: tempDir.appendingPathComponent("deinit.sqlite"))
        let config = ARTrackerConfig(flushInterval: 60.0)

        ({
            let uploader = Uploader(endpoint: dummyEndpoint, appKey: "art_test_key", config: config, queue: queue)
            weakUploader = uploader
            uploader.start()
            uploader.suspendTimer()
            XCTAssertTrue(uploader.isTimerSuspendedForTesting)
        })()

        // Allow initial flush dispatched by start() on workQueue to finish and release `self`
        let deadline = Date().addingTimeInterval(2.0)
        while weakUploader != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertNil(weakUploader)
    }

    func testSuspendAndResumeBeforeStartAreNoOps() {
        let uploader = makeUploader()
        uploader.suspendTimer()
        uploader.resumeTimer()

        XCTAssertFalse(uploader.hasTimerForTesting)
        XCTAssertFalse(uploader.isTimerSuspendedForTesting)
    }
}

