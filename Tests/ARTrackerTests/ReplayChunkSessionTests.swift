import XCTest
@testable import ARTracker

final class ReplayChunkSessionTests: XCTestCase {

    final class SpyReplayUploader: ReplayUploading, @unchecked Sendable {
        private let lock = NSLock()
        var requestedChunks: [(sessionId: String, seq: Int, startTime: String)] = []
        var ackedChunks: [(sessionId: String, seq: Int, durationMs: Double)] = []
        var requestChunkUrlCallCount: Int = 0
        var shouldReturnScreenshotDisabled: Bool = false
        var simulatedRetryAfterSeconds: TimeInterval? = nil

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
            format: String = "artracker-mobile-v1",
            completion: @escaping @Sendable (Result<(uploadUrl: URL, objectKey: String), Error>) -> Void
        ) {
            lock.withLock {
                requestChunkUrlCallCount += 1
                requestedChunks.append((sessionId: sessionId, seq: chunkSeq, startTime: startTime))
            }

            if shouldReturnScreenshotDisabled {
                completion(.failure(ReplayUploadError.screenshotDisabled))
                return
            }

            if let retry = simulatedRetryAfterSeconds {
                completion(.failure(ReplayUploadError.httpError(statusCode: 429, message: "Too Many Requests", retryAfter: retry)))
                return
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
                ackedChunks.append((sessionId: sessionId, seq: chunkSeq, durationMs: durationMs))
            }
            completion(.success(()))
        }
    }

    final class StubReplayUploader: ReplayUploading, @unchecked Sendable {
        private let lock = NSLock()
        var requestedSessionIds: [String] = []

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
            format: String = "artracker-mobile-v1",
            completion: @escaping @Sendable (Result<(uploadUrl: URL, objectKey: String), Error>) -> Void
        ) {
            lock.withLock {
                requestedSessionIds.append(sessionId)
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
            completion(.success(()))
        }
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

    private func makeSampleFrame(ts: Int64 = 1_000_000) -> ScreenFramePayload {
        ScreenFramePayload(
            ts: ts,
            screen: "Home",
            w: 320,
            h: 480,
            vw: 320.0,
            vh: 480.0,
            mime: "image/jpeg",
            data: "dGVzdA=="
        )
    }

    private func flushAndWait(_ manager: ReplayChunkManager) {
        let exp = expectation(description: "flush")
        manager.flush {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    private func makeDummyFrame(ts: Int64 = 1_000_000) -> ScreenFramePayload {
        makeSampleFrame(ts: ts)
    }

    func testAckDurationIsCumulativeAcrossMultipleChunks() throws {
        final class FakeClock: @unchecked Sendable {
            var uptime: TimeInterval = 1_000.0
            var date: Date = Date(timeIntervalSince1970: 1_700_000_000)
        }
        let clock = FakeClock()
        let spy = SpyReplayUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { "ses_cumulative_1" },
            uptimeProvider: { clock.uptime },
            dateProvider: { clock.date }
        )

        // Chunk 0 pada t = +10s
        manager.appendScreenFrame(makeDummyFrame(ts: 1000))
        clock.uptime = 1_010.0
        flushAndWait(manager)

        // Chunk 1 pada t = +20s
        manager.appendScreenFrame(makeDummyFrame(ts: 2000))
        clock.uptime = 1_020.0
        flushAndWait(manager)

        // Chunk 2 pada t = +30s
        manager.appendScreenFrame(makeDummyFrame(ts: 3000))
        clock.uptime = 1_030.0
        flushAndWait(manager)

        XCTAssertEqual(spy.ackedChunks.count, 3)
        XCTAssertEqual(spy.ackedChunks[0].seq, 0)
        XCTAssertEqual(spy.ackedChunks[0].durationMs, 10_000, accuracy: 1.0)
        XCTAssertEqual(spy.ackedChunks[1].seq, 1)
        XCTAssertEqual(spy.ackedChunks[1].durationMs, 20_000, accuracy: 1.0)
        XCTAssertEqual(spy.ackedChunks[2].seq, 2)
        XCTAssertEqual(spy.ackedChunks[2].durationMs, 30_000, accuracy: 1.0)
    }

    func testSessionRotationResetsSeqDurationAndStartTime() throws {
        final class FakeState: @unchecked Sendable {
            var sessionId = "ses_first"
            var uptime: TimeInterval = 500.0
            var date: Date = Date(timeIntervalSince1970: 1_700_000_000)
        }
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

        // Sesi pertama: 2 chunk
        manager.appendScreenFrame(makeDummyFrame(ts: 1))
        state.uptime = 510.0
        flushAndWait(manager)

        manager.appendScreenFrame(makeDummyFrame(ts: 2))
        state.uptime = 525.0
        flushAndWait(manager)

        // Idle 40 menit -> rotasi ke sesi kedua pada uptime = 3000.0
        state.uptime = 3_000.0
        let secondSessionDate = Date(timeIntervalSince1970: 1_700_002_400)
        state.date = secondSessionDate
        state.sessionId = "ses_second"

        manager.appendScreenFrame(makeDummyFrame(ts: 3))
        state.uptime = 3_012.0
        flushAndWait(manager)

        XCTAssertEqual(spy.ackedChunks.count, 3)
        // Sesi pertama chunk 0 & 1
        XCTAssertEqual(spy.ackedChunks[0].sessionId, "ses_first")
        XCTAssertEqual(spy.ackedChunks[0].seq, 0)
        XCTAssertEqual(spy.ackedChunks[0].durationMs, 10_000, accuracy: 1.0)
        XCTAssertEqual(spy.ackedChunks[1].sessionId, "ses_first")
        XCTAssertEqual(spy.ackedChunks[1].seq, 1)
        XCTAssertEqual(spy.ackedChunks[1].durationMs, 25_000, accuracy: 1.0)

        // Sesi kedua harus mulai kembali dari seq = 0 dan durasi 12_000 ms (bukan 2_512_000 ms)
        XCTAssertEqual(spy.ackedChunks[2].sessionId, "ses_second")
        XCTAssertEqual(spy.ackedChunks[2].seq, 0)
        XCTAssertEqual(spy.ackedChunks[2].durationMs, 12_000, accuracy: 1.0)

        let expectedStartTime = ISO8601DateFormatter().string(from: secondSessionDate)
        XCTAssertEqual(spy.requestedChunks.last?.startTime, expectedStartTime)
    }

    func testScreenshotDisabledClearsQueueAndIgnoresSubsequentFramesAndTouches() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var value = 0
            func inc() { lock.withLock { value += 1 } }
        }
        let counter = Counter()
        let spy = SpyReplayUploader()
        spy.shouldReturnScreenshotDisabled = true
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { "ses_disabled" }
        )
        manager.onScreenshotDisabled = {
            counter.inc()
        }

        manager.appendScreenFrame(makeDummyFrame(ts: 1))
        flushAndWait(manager)

        XCTAssertEqual(counter.value, 1)
        XCTAssertNil(queue.peekNext())

        // Setelah screenshot_disabled, touch maupun frame baru tidak boleh masuk antrean lagi
        spy.shouldReturnScreenshotDisabled = false
        manager.appendScreenTouch(ScreenTouchPoint(ts: 2, x: 10, y: 20, kind: "down"))
        manager.appendScreenFrame(makeDummyFrame(ts: 3))
        flushAndWait(manager)

        XCTAssertNil(queue.peekNext())
        XCTAssertEqual(spy.ackedChunks.count, 0)
    }

    func testRetryAfterDelaysSubsequentUploadAttempts() {
        final class FakeClock: @unchecked Sendable {
            var uptime: TimeInterval = 100.0
        }
        let clock = FakeClock()
        let spy = SpyReplayUploader()
        spy.simulatedRetryAfterSeconds = 30.0
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { "ses_retry" },
            uptimeProvider: { clock.uptime }
        )

        manager.appendScreenFrame(makeDummyFrame(ts: 1))
        flushAndWait(manager) // Gagal dengan Retry-After: 30s
        XCTAssertEqual(spy.ackedChunks.count, 0)
        let attemptsAfterFirstTry = spy.requestChunkUrlCallCount

        // Pada t = +10s (masih dalam masa Retry-After 30s), flush tidak boleh memanggil requestChunkUrl
        spy.simulatedRetryAfterSeconds = nil
        clock.uptime = 110.0
        flushAndWait(manager)
        XCTAssertEqual(spy.requestChunkUrlCallCount, attemptsAfterFirstTry)
        XCTAssertEqual(spy.ackedChunks.count, 0)

        // Pada t = +31s (lewat masa Retry-After), flush berhasil mengunggah chunk
        clock.uptime = 131.0
        flushAndWait(manager)
        XCTAssertEqual(spy.ackedChunks.count, 1)
    }

    func testChunkUploadedUnderRecordingSession() {
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let stubUploader = StubReplayUploader()

        final class MutableSession: @unchecked Sendable {
            var currentId: String = "ses_session_A"
        }
        let sessionBox = MutableSession()

        let manager = ReplayChunkManager(
            uploader: stubUploader,
            environment: "test",
            wifiOnly: false,
            diskQueue: diskQueue,
            sessionIdProvider: { sessionBox.currentId }
        )

        // Append frame under Session A
        manager.appendScreenFrame(makeSampleFrame(ts: 1_000_000))

        // Session rotates to Session B before upload completes
        sessionBox.currentId = "ses_session_B"

        let exp = expectation(description: "Upload completed")
        manager.flush {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        // Uploader must receive Session A, because that's when chunk was recorded
        XCTAssertEqual(stubUploader.requestedSessionIds, ["ses_session_A"])
    }

    func testLegacyQueueItemWithoutSessionIdDecodes() throws {
        // Construct JSON representing a pre-upgrade chunk item without `sessionId`
        let legacyJson = """
        {
            "id": "item-1234",
            "seq": 0,
            "format": "artracker-screen-v1",
            "count": 1,
            "duration": 500.0,
            "hasError": false,
            "hasRage": false,
            "startTime": "2026-11-16T08:00:00Z",
            "createdAt": 1731744000.0,
            "data": "dGVzdA=="
        }
        """

        let decoded = try JSONDecoder().decode(ReplayQueueItem.self, from: legacyJson.data(using: .utf8)!)
        XCTAssertNil(decoded.sessionId)

        // When enqueued and uploaded, fallback should use current sessionIdProvider
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        diskQueue.enqueue(decoded)

        let stubUploader = StubReplayUploader()
        let manager = ReplayChunkManager(
            uploader: stubUploader,
            environment: "test",
            wifiOnly: false,
            diskQueue: diskQueue,
            sessionIdProvider: { "ses_fallback_provider" }
        )

        let exp = expectation(description: "Legacy upload completed")
        manager.flush {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(stubUploader.requestedSessionIds, ["ses_fallback_provider"])
    }

    func testSessionChangeMidChunkSplitsChunk() {
        let diskQueue = ReplayDiskQueue(customDirectory: tempDir)
        let stubUploader = StubReplayUploader()

        final class MutableSession: @unchecked Sendable {
            var currentId: String = "ses_first"
        }
        let sessionBox = MutableSession()

        let manager = ReplayChunkManager(
            uploader: stubUploader,
            environment: "test",
            wifiOnly: false,
            diskQueue: diskQueue,
            sessionIdProvider: { sessionBox.currentId }
        )

        // Append frame under ses_first
        manager.appendScreenFrame(makeSampleFrame(ts: 1_000_000))

        // Session rotates mid-chunk
        sessionBox.currentId = "ses_second"

        // Append frame under ses_second -> should split into two chunks
        manager.appendScreenFrame(makeSampleFrame(ts: 1_001_000))

        let exp = expectation(description: "Uploads completed")
        manager.flush {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(stubUploader.requestedSessionIds, ["ses_first", "ses_second"])
    }
}
