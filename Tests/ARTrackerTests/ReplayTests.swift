import XCTest
@testable import ARTracker
#if canImport(UIKit)
import UIKit
#endif

final class ReplayTests: XCTestCase {

    final class SpyChunkUploader: ReplayUploading, @unchecked Sendable {
        private let lock = NSLock()
        var ackedEventCounts: [Int] = []

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
                ackedEventCounts.append(eventCount)
            }
            completion(.success(()))
        }
    }

    func testChunkClosesWhenApproachingTwoMegabytes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let spy = SpyChunkUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "test",
            diskQueue: queue,
            sessionIdProvider: { "ses_size_cap" }
        )

        // Buat payload sekitar 900 KB per frame (base64)
        let largeData = String(repeating: "A", count: 900_000)
        let frame1 = ScreenFramePayload(ts: 1, screen: "Home", w: 720, h: 1280, vw: 360, vh: 640, data: largeData)
        let frame2 = ScreenFramePayload(ts: 2, screen: "Home", w: 720, h: 1280, vw: 360, vh: 640, data: largeData)
        let frame3 = ScreenFramePayload(ts: 3, screen: "Home", w: 720, h: 1280, vw: 360, vh: 640, data: largeData)

        manager.appendScreenFrame(frame1) // ~900 KB
        manager.appendScreenFrame(frame2) // ~1.8 MB (masih <= 2 MB)
        manager.appendScreenFrame(frame3) // akan menjadi ~2.7 MB -> harus memicu flush frame1+frame2 lebih dulu!

        let exp = expectation(description: "flush")
        manager.flush { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(spy.ackedEventCounts, [2, 1])
    }

    func testScreenChunkPayloadMatchesOfficialContract() throws {
        let frame = ScreenFramePayload(
            ts: 1731143820120,
            screen: "DashboardView",
            w: 720,
            h: 1560,
            vw: 393.0,
            vh: 852.0,
            mime: "image/jpeg",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            masked: true
        )

        let touches = [
            ScreenTouchPoint(ts: 1731143822100, x: 150.0, y: 320.0, kind: "down"),
            ScreenTouchPoint(ts: 1731143822150, x: 155.0, y: 340.0, kind: "move"),
            ScreenTouchPoint(ts: 1731143822200, x: 160.0, y: 360.0, kind: "up")
        ]

        let chunk = ScreenChunkPayload(
            format: "artracker-screen-v1",
            platform: "ios",
            seq: 3,
            frames: [frame],
            touches: touches
        )

        let data = try JSONEncoder().encode(chunk)
        XCTAssertFalse(data.isEmpty)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["format"] as? String, "artracker-screen-v1")
        XCTAssertEqual(json?["platform"] as? String, "ios")
        XCTAssertEqual(json?["seq"] as? Int, 3)

        let frames = json?["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.count, 1)
        XCTAssertEqual(frames?[0]["screen"] as? String, "DashboardView")
        XCTAssertEqual(frames?[0]["w"] as? Int, 720)
        XCTAssertEqual(frames?[0]["h"] as? Int, 1560)
        XCTAssertEqual(frames?[0]["vw"] as? Double, 393.0)
        XCTAssertEqual(frames?[0]["vh"] as? Double, 852.0)
        XCTAssertEqual(frames?[0]["mime"] as? String, "image/jpeg")
        XCTAssertEqual(frames?[0]["masked"] as? Bool, true)

        let serializedTouches = json?["touches"] as? [[String: Any]]
        XCTAssertEqual(serializedTouches?.count, 3)
        XCTAssertEqual(serializedTouches?[0]["kind"] as? String, "down")
        XCTAssertEqual(serializedTouches?[0]["x"] as? Double, 150.0)
        XCTAssertEqual(serializedTouches?[1]["kind"] as? String, "move")
        XCTAssertEqual(serializedTouches?[1]["x"] as? Double, 155.0)
        XCTAssertEqual(serializedTouches?[2]["kind"] as? String, "up")
        XCTAssertEqual(serializedTouches?[2]["x"] as? Double, 160.0)

        let compressed = try Gzip.compress(data: data)
        XCTAssertTrue(Gzip.isGzip(data: compressed))
    }

    func testReplayQualityPresets() {
        XCTAssertEqual(ReplayQuality.low.shortSidePx, 480)
        XCTAssertEqual(ReplayQuality.low.jpegQuality, 0.5)
        XCTAssertEqual(ReplayQuality.low.lowerPreset, .low)

        XCTAssertEqual(ReplayQuality.standard.shortSidePx, 720)
        XCTAssertEqual(ReplayQuality.standard.jpegQuality, 0.6)
        XCTAssertEqual(ReplayQuality.standard.lowerPreset, .low)

        XCTAssertEqual(ReplayQuality.high.shortSidePx, 1080)
        XCTAssertEqual(ReplayQuality.high.jpegQuality, 0.75)
        XCTAssertEqual(ReplayQuality.high.lowerPreset, .standard)
    }

    func testReplayConfigClampingAndDefaults() {
        let defaultConfig = ARTrackerConfig()
        XCTAssertEqual(defaultConfig.replayQuality, .standard)
        XCTAssertEqual(defaultConfig.replayFramesPerSecond, 2.0)

        let underMin = ARTrackerConfig(replayFramesPerSecond: 0.1)
        XCTAssertEqual(underMin.replayFramesPerSecond, 0.5)

        let overMax = ARTrackerConfig(replayFramesPerSecond: 25.0)
        XCTAssertEqual(overMax.replayFramesPerSecond, 10.0)
    }

    func testReplayDiskQueuePersistenceAndCap() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let item1 = ReplayQueueItem(
            id: "chunk-1",
            seq: 0,
            format: "artracker-screen-v1",
            count: 2,
            duration: 1000.0,
            hasError: false,
            hasRage: false,
            startTime: "2026-11-10T00:00:00Z",
            createdAt: Date(timeIntervalSince1970: 1731143820),
            data: Data("screen-data-1".utf8)
        )
        let item2 = ReplayQueueItem(
            id: "chunk-2",
            seq: 1,
            format: "artracker-screen-v1",
            count: 5,
            duration: 2000.0,
            hasError: false,
            hasRage: false,
            startTime: "2026-11-10T00:00:10Z",
            createdAt: Date(timeIntervalSince1970: 1731143830),
            data: Data("screen-data-2".utf8)
        )

        queue.enqueue(item1)
        queue.enqueue(item2)

        let peeked = queue.peekNext()
        XCTAssertNotNil(peeked)
        XCTAssertEqual(peeked?.id, "chunk-1")

        queue.remove(id: "chunk-1")
        let peekedAfter = queue.peekNext()
        XCTAssertEqual(peekedAfter?.id, "chunk-2")

        queue.clearScreenshotChunks()
        XCTAssertNil(queue.peekNext())
    }

    func testReplayRemoteConfigDecoding() throws {
        let jsonStr = """
        {
            "screenshot_enabled": true,
            "max_fps": 4.0
        }
        """
        let data = Data(jsonStr.utf8)
        let config = try JSONDecoder().decode(ReplayRemoteConfig.self, from: data)
        XCTAssertTrue(config.screenshotEnabled)
        XCTAssertEqual(config.maxFps, 4.0)
    }

    func testByteBudgetGovernor() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let queue = ReplayDiskQueue(customDirectory: tempDir)

        XCTAssertFalse(queue.shouldHalveFps())
        // Exceed 5 MB
        queue.recordBytes(6 * 1024 * 1024)
        XCTAssertTrue(queue.shouldHalveFps())
    }

    func testMaskingRulesExtendedForSensitiveContent() throws {
        XCTAssertEqual(MaskingRules.maskText("secret123"), "*********")
        XCTAssertEqual(MaskingRules.maskText(""), "")
        XCTAssertEqual(MaskingRules.maskText(nil), "")

        #if canImport(UIKit)
        let customView = UIView()
        XCTAssertFalse(MaskingRules.shouldMask(view: customView, maskAllText: false))

        customView.artrackerMasked = true
        XCTAssertTrue(MaskingRules.shouldMask(view: customView, maskAllText: false))

        let marker = _ARTrackerMaskMarkerView()
        XCTAssertTrue(marker.artrackerMasked)
        XCTAssertTrue(MaskingRules.shouldMask(view: marker, maskAllText: false))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        window.isHidden = false
        let child = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 50))
        child.artrackerMasked = true
        window.addSubview(child)

        let rects = try MaskingRules.collectMaskRects(in: window, maskAllText: false)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first, CGRect(x: 10, y: 10, width: 100, height: 50))
        #endif
    }

    func testScreenTouchPointCodableAndKinds() throws {
        let down = ScreenTouchPoint(ts: 1000, x: 50.0, y: 100.0, kind: "down")
        let move = ScreenTouchPoint(ts: 1040, x: 55.0, y: 120.0, kind: "move")
        let up = ScreenTouchPoint(ts: 1100, x: 60.0, y: 150.0, kind: "up")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let downData = try encoder.encode(down)
        let decodedDown = try decoder.decode(ScreenTouchPoint.self, from: downData)
        XCTAssertEqual(decodedDown, down)
        XCTAssertEqual(decodedDown.kind, "down")

        let moveData = try encoder.encode(move)
        let decodedMove = try decoder.decode(ScreenTouchPoint.self, from: moveData)
        XCTAssertEqual(decodedMove, move)
        XCTAssertEqual(decodedMove.kind, "move")

        let upData = try encoder.encode(up)
        let decodedUp = try decoder.decode(ScreenTouchPoint.self, from: upData)
        XCTAssertEqual(decodedUp, up)
        XCTAssertEqual(decodedUp.kind, "up")
    }

    func testProducedGzipChunkDecompressesAndMatchesContractWithFramesAndTouches() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class CapturingUploader: ReplayUploading, @unchecked Sendable {
            var uploadedGzipData: Data?
            var ackedEventCount: Int?
            var requestedFormat: String?

            func fetchReplayConfig(completion: @escaping @Sendable (Result<ReplayRemoteConfig, Error>) -> Void) {
                completion(.success(ReplayRemoteConfig(screenshotEnabled: true, maxFps: 2.0)))
            }
            func requestChunkUrl(
                sessionId: String, chunkSeq: Int, sizeBytes: Int, userId: String?,
                environment: String, startTime: String, format: String,
                completion: @escaping @Sendable (Result<(uploadUrl: URL, objectKey: String), Error>) -> Void
            ) {
                requestedFormat = format
                completion(.success((URL(string: "https://example.com/upload")!, "key_\(chunkSeq)")))
            }
            func uploadGzipData(uploadUrl: URL, gzipData: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
                uploadedGzipData = gzipData
                completion(.success(()))
            }
            func acknowledgeChunk(
                sessionId: String, chunkSeq: Int, sizeBytes: Int, durationMs: Double,
                eventCount: Int, hasError: Bool, hasRageClick: Bool,
                completion: @escaping @Sendable (Result<Void, Error>) -> Void
            ) {
                ackedEventCount = eventCount
                completion(.success(()))
            }
        }

        let spy = CapturingUploader()
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let manager = ReplayChunkManager(
            uploader: spy,
            environment: "production",
            diskQueue: queue,
            sessionIdProvider: { "ses_contract" }
        )

        manager.appendScreenFrame(ScreenFramePayload(ts: 100, screen: "Home", w: 720, h: 1280, vw: 360, vh: 640, data: "dGVzdA==", masked: true))
        manager.appendScreenFrame(ScreenFramePayload(ts: 200, screen: "Detail", w: 720, h: 1280, vw: 360, vh: 640, data: "dGVzdDI=", masked: false))
        manager.appendScreenTouch(ScreenTouchPoint(ts: 150, x: 120, y: 240, kind: "down"))
        manager.appendScreenTouch(ScreenTouchPoint(ts: 180, x: 120, y: 240, kind: "up"))

        let exp = expectation(description: "flush")
        manager.flush { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(spy.requestedFormat, "artracker-screen-v1")
        XCTAssertEqual(spy.ackedEventCount, 4) // 2 frames + 2 touches

        let gzipData = try XCTUnwrap(spy.uploadedGzipData)
        XCTAssertTrue(Gzip.isGzip(data: gzipData))
        let rawJson = try Gzip.decompress(data: gzipData)
        let decoded = try JSONDecoder().decode(ScreenChunkPayload.self, from: rawJson)
        XCTAssertEqual(decoded.format, "artracker-screen-v1")
        XCTAssertEqual(decoded.platform, "ios")
        XCTAssertEqual(decoded.seq, 0)
        XCTAssertEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.touches.count, 2)
    }
}
