import XCTest
@testable import ARTracker

final class ReplayChunkUserTests: XCTestCase {
    final class CapturingChunkUploader: ReplayUploading, @unchecked Sendable {
        private let lock = NSLock()
        var requestedSessionIds: [String] = []
        var requestedUserIds: [String?] = []

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
                requestedSessionIds.append(sessionId)
                requestedUserIds.append(userId)
            }
            completion(.success((URL(string: "https://example.com/upload")!, "key_\(chunkSeq)")))
        }

        func uploadGzipData(uploadUrl: URL, gzipData: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
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

    func testChunkUploadsWithSealTimeUser() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class MutableContext: @unchecked Sendable {
            var currentSession = "ses_user_a"
            var currentUser: String? = "user_A"
        }
        let ctx = MutableContext()

        let uploader = CapturingChunkUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let manager = ReplayChunkManager(
            uploader: uploader,
            environment: "production",
            diskQueue: queue,
            sessionIdProvider: { ctx.currentSession },
            userIdProvider: { ctx.currentUser }
        )

        // Append frame under user_A and ses_user_a
        manager.appendScreenFrame(
            ScreenFramePayload(ts: 100, screen: "Home", w: 720, h: 1280, vw: 360, vh: 640, data: "dGVzdA==", masked: true)
        )

        // Seal chunk under session A / user A
        let exp1 = expectation(description: "flush user A")
        manager.flush { exp1.fulfill() }
        wait(for: [exp1], timeout: 5.0)

        // Now change context to user_B and ses_user_b
        ctx.currentSession = "ses_user_b"
        ctx.currentUser = "user_B"

        // Verify upload request received user A!
        XCTAssertEqual(uploader.requestedSessionIds, ["ses_user_a"])
        XCTAssertEqual(uploader.requestedUserIds, ["user_A"])
    }

    func testAnonymousChunkUploadsWithNilUserWithoutFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class MutableContext: @unchecked Sendable {
            var currentSession = "ses_anon"
            var currentUser: String? = nil
        }
        let ctx = MutableContext()

        let uploader = CapturingChunkUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let manager = ReplayChunkManager(
            uploader: uploader,
            environment: "production",
            diskQueue: queue,
            sessionIdProvider: { ctx.currentSession },
            userIdProvider: { ctx.currentUser }
        )

        // Append frame while anonymous
        manager.appendScreenFrame(
            ScreenFramePayload(ts: 100, screen: "Home", w: 720, h: 1280, vw: 360, vh: 640, data: "dGVzdA==", masked: true)
        )

        let exp = expectation(description: "flush anon")
        manager.flush { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        // User logs in now
        ctx.currentUser = "user_logged_in_later"

        XCTAssertEqual(uploader.requestedSessionIds, ["ses_anon"])
        XCTAssertEqual(uploader.requestedUserIds, [nil])
    }

    func testLegacyChunkDecodesWithNilUser() throws {
        let jsonStr = """
        {
            "id": "legacy_chunk",
            "seq": 0,
            "format": "artracker-screen-v1",
            "count": 1,
            "duration": 500.0,
            "hasError": false,
            "hasRage": false,
            "startTime": "2026-11-19T00:00:00Z",
            "createdAt": 1732000000,
            "data": "dGVzdA=="
        }
        """
        let data = Data(jsonStr.utf8)
        let item = try JSONDecoder().decode(ReplayQueueItem.self, from: data)
        XCTAssertEqual(item.id, "legacy_chunk")
        XCTAssertNil(item.userId)
    }
}
