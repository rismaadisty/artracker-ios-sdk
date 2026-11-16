import XCTest
@testable import ARTracker

final class ReplayChunkSessionTests: XCTestCase {

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
