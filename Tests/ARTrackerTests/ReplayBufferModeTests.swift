import XCTest
@testable import ARTracker

final class ReplayBufferModeTests: XCTestCase {
    final class SpyReplayUploader: ReplayUploading, @unchecked Sendable {
        private let lock = NSLock()
        var requestedChunks: [(sessionId: String, seq: Int, startTime: String)] = []
        var ackedChunks: [(sessionId: String, seq: Int, hasError: Bool)] = []

        func fetchReplayConfig(completion: @escaping @Sendable (Result<ReplayRemoteConfig, Error>) -> Void) {
            completion(.success(ReplayRemoteConfig(screenshotEnabled: true, maxFps: 2.0)))
        }

        func requestChunkUrl(
            sessionId: String,
            chunkSeq: Int,
            sizeBytes: Int,
            userId: String?,
            environment: String,
            startTime: String,
            format: String,
            completion: @escaping @Sendable (Result<(uploadUrl: URL, objectKey: String), Error>) -> Void
        ) {
            lock.withLock {
                requestedChunks.append((sessionId, chunkSeq, startTime))
            }
            completion(.success((URL(string: "https://example.com/upload")!, "key_\(chunkSeq)")))
        }

        func uploadGzipData(
            uploadUrl: URL,
            gzipData: Data,
            completion: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            completion(.success(()))
        }

        func acknowledgeChunk(
            sessionId: String,
            chunkSeq: Int,
            sizeBytes: Int,
            durationMs: Double,
            eventCount: Int,
            hasError: Bool,
            hasRageClick: Bool,
            completion: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            lock.withLock {
                ackedChunks.append((sessionId, chunkSeq, hasError))
            }
            completion(.success(()))
        }
    }

    final class FakeState: @unchecked Sendable {
        var sessionId = "ses_buf_1"
        var uptime: TimeInterval = 1_000.0
        var date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    private func makeDummyFrame(ts: Int64 = 1) -> ScreenFramePayload {
        ScreenFramePayload(ts: ts, screen: "Home", w: 100, h: 200, vw: 100, vh: 200, data: "AAAA")
    }

    private func flushAndWait(_ manager: ReplayChunkManager) {
        let exp = expectation(description: "flush")
        manager.flush { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    func testBufferModeChunksAreHeldAndNeverUploadedWithoutError() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.buffer, sessionId: state.sessionId)

        // Append frame and flush
        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        state.uptime = 1_005.0
        flushAndWait(manager)

        // Queue has 0 pending (because it's held), spy acked 0
        XCTAssertEqual(queue.pendingCount(), 0)
        XCTAssertEqual(spy.ackedChunks.count, 0)
    }

    func testBufferModeErrorClosesOpenChunkWithHasErrorAndPromotesAllHeldInOrder() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.buffer, sessionId: state.sessionId)

        // Chunk 1 (held)
        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        state.uptime = 1_005.0
        flushAndWait(manager)

        // Chunk 2 (partially buffered, currently open)
        manager.appendScreenFrame(makeDummyFrame(ts: 6000))
        state.uptime = 1_008.0

        // Error triggers!
        let exp = expectation(description: "error upload")
        manager.onError()
        // Wait a bit for async worker queue upload
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            manager.flush { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5.0)

        // Both chunk 1 and chunk 2 should have been promoted and uploaded
        XCTAssertEqual(spy.ackedChunks.count, 2)
        XCTAssertEqual(spy.ackedChunks[0].seq, 0)
        XCTAssertFalse(spy.ackedChunks[0].hasError)
        XCTAssertEqual(spy.ackedChunks[1].seq, 1)
        XCTAssertTrue(spy.ackedChunks[1].hasError)
    }

    func testBufferModeFollowUp30sShipsReadyChunksThenReturnsToHeld() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.buffer, sessionId: state.sessionId)

        // Trigger error at t = 1000.0
        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        manager.onError()
        flushAndWait(manager)

        XCTAssertEqual(spy.ackedChunks.count, 1)

        // Chunk at t = +10s (inside 30s follow-up window) -> should be ready and uploaded
        state.uptime = 1_010.0
        manager.appendScreenFrame(makeDummyFrame(ts: 11000))
        flushAndWait(manager)
        XCTAssertEqual(spy.ackedChunks.count, 2)
        XCTAssertEqual(spy.ackedChunks[1].seq, 1)

        // Chunk at t = +35s (outside 30s follow-up window) -> should be held again!
        state.uptime = 1_035.0
        manager.appendScreenFrame(makeDummyFrame(ts: 36000))
        flushAndWait(manager)
        // No new upload
        XCTAssertEqual(spy.ackedChunks.count, 2)
        XCTAssertEqual(queue.pendingCount(), 0)
    }

    func testBufferModeErrorBurstPromotesOnlyOnceWithin60sAndMax3PerSession() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.buffer, sessionId: state.sessionId)

        // 1st error admitted at t = 1000
        state.uptime = 1_000.0
        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        manager.onError()
        flushAndWait(manager)
        XCTAssertEqual(spy.ackedChunks.count, 1)

        // 2nd error at t = 1010 (< 60s gap) -> rejected by policy
        state.uptime = 1_010.0
        manager.appendScreenFrame(makeDummyFrame(ts: 11000))
        manager.onError() // should NOT promote or extend follow-up
        flushAndWait(manager)
        // Since t=1010 was still in the 1st follow-up window, the frame uploaded as part of follow-up
        XCTAssertEqual(spy.ackedChunks.count, 2)

        // Advance to t = 1040 (follow up ended at 1030). New frame is held.
        state.uptime = 1_040.0
        manager.appendScreenFrame(makeDummyFrame(ts: 41000))
        flushAndWait(manager)
        XCTAssertEqual(spy.ackedChunks.count, 2)

        // 3rd error at t = 1050 (still < 60s gap since 1000) -> rejected by policy
        state.uptime = 1_050.0
        manager.onError()
        flushAndWait(manager)
        XCTAssertEqual(spy.ackedChunks.count, 2) // not uploaded

        // 4th error at t = 1065 (>= 60s gap from 1000) -> admitted!
        state.uptime = 1_065.0
        manager.onError()
        flushAndWait(manager)
        XCTAssertEqual(spy.ackedChunks.count, 3) // chunk at 1040 promoted & uploaded
    }

    func testBufferModeSessionChangeDiscardsOldSessionHeldChunks() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.buffer, sessionId: "ses_old")

        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        flushAndWait(manager)
        XCTAssertEqual(queue.pendingCount(), 0)

        // Session changes to ses_new
        state.sessionId = "ses_new"
        manager.setRecordingMode(.buffer, sessionId: "ses_new")

        // ses_old held chunks should be dropped from disk
        // If an error happens in ses_new, ses_old chunk is NOT promoted
        manager.appendScreenFrame(makeDummyFrame(ts: 2000))
        manager.onError()
        flushAndWait(manager)

        XCTAssertEqual(spy.ackedChunks.count, 1)
        XCTAssertEqual(spy.ackedChunks[0].sessionId, "ses_new")
    }

    func testBufferModeBackgroundClosesChunkAsHeldWithoutUploading() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.buffer, sessionId: state.sessionId)

        manager.appendScreenFrame(makeDummyFrame(ts: 1000))

        let exp = expectation(description: "bg")
        manager.handleDidEnterBackground {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        // Queue has 0 pending (held), spy has 0 uploads
        XCTAssertEqual(queue.pendingCount(), 0)
        XCTAssertEqual(spy.ackedChunks.count, 0)
    }

    func testFullModeUnchangedUploadsEveryChunkImmediately() {
        let state = FakeState()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { state.sessionId },
            uptimeProvider: { state.uptime },
            dateProvider: { state.date }
        )
        manager.setRecordingMode(.full, sessionId: state.sessionId)

        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        flushAndWait(manager)

        XCTAssertEqual(spy.ackedChunks.count, 1)
        XCTAssertEqual(spy.ackedChunks[0].seq, 0)
    }

    func testPreviousRunHoldingsPromotesOnCrashAndDropsOnCleanExit() {
        let processStartDate = Date()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        // Setup held chunk from previous process run
        let oldItem = ReplayQueueItem(
            id: "prev_crash_chunk",
            seq: -1,
            format: "artracker-screen-v1",
            count: 1,
            duration: 5000.0,
            hasError: false,
            hasRage: false,
            startTime: "2026-11-24T00:00:00.000Z",
            createdAt: processStartDate.addingTimeInterval(-10),
            data: try! Gzip.compress(data: JSONEncoder().encode(ScreenChunkPayload(seq: -1, frames: [], touches: []))),
            sessionId: "ses_prev",
            held: true,
            firstTsMs: 1000,
            lastTsMs: 6000
        )
        queue.enqueue(oldItem)

        let spy = SpyReplayUploader()
        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { "ses_new" }
        )

        // Relaunch with crash: should promote and upload
        manager.handlePreviousRunHoldings(previousRunCrashed: true, processStartDate: processStartDate)

        let exp = expectation(description: "crash upload")
        manager.flush { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(spy.ackedChunks.count, 1)
        XCTAssertEqual(spy.ackedChunks[0].sessionId, "ses_prev")
    }

    func testCleanRelaunchDropsPreviousBufferChunks() {
        let processStartDate = Date()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let oldItem = ReplayQueueItem(
            id: "prev_clean_chunk",
            seq: -1,
            format: "artracker-screen-v1",
            count: 1,
            duration: 5000.0,
            hasError: false,
            hasRage: false,
            startTime: "2026-11-24T00:00:00.000Z",
            createdAt: processStartDate.addingTimeInterval(-10),
            data: try! Gzip.compress(data: JSONEncoder().encode(ScreenChunkPayload(seq: -1, frames: [], touches: []))),
            sessionId: "ses_clean",
            held: true,
            firstTsMs: 1000,
            lastTsMs: 6000
        )
        queue.enqueue(oldItem)

        let spy = SpyReplayUploader()
        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { "ses_clean_new" }
        )

        // Relaunch clean (no crash)
        manager.handlePreviousRunHoldings(previousRunCrashed: false, processStartDate: processStartDate)

        let exp = expectation(description: "clean flush")
        manager.flush { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(spy.ackedChunks.count, 0)
        XCTAssertEqual(queue.pendingCount(), 0)
    }

    #if canImport(UIKit)
    func testReplayEngineSessionModeEvaluation() {
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        // 1. Full mode sampler
        ReplayEngine.shared.startForTesting(
            uploader: ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "k"),
            diskQueue: queue,
            sampleRate: 1.0,
            onErrorSampleRate: 0.0,
            clock: { 0 }
        )
        XCTAssertEqual(ReplayEngine.shared.currentModeForTesting, .full)
        ReplayEngine.shared.resetForTesting()

        // 2. Buffer mode sampler (default: sampleRate 0.0, onError 1.0)
        ReplayEngine.shared.startForTesting(
            uploader: ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "k"),
            diskQueue: queue,
            sampleRate: 0.0,
            onErrorSampleRate: 1.0,
            clock: { 0 }
        )
        XCTAssertEqual(ReplayEngine.shared.currentModeForTesting, .buffer)
        ReplayEngine.shared.resetForTesting()

        // 3. Not sampled (both 0.0)
        ReplayEngine.shared.startForTesting(
            uploader: ReplayUploader(endpoint: URL(string: "https://example.com")!, appKey: "k"),
            diskQueue: queue,
            sampleRate: 0.0,
            onErrorSampleRate: 0.0,
            clock: { 0 }
        )
        XCTAssertNil(ReplayEngine.shared.currentModeForTesting)
        ReplayEngine.shared.resetForTesting()
    }
    #endif
}
