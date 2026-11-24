import XCTest
@testable import ARTracker

final class ReplayBufferStoreTests: XCTestCase {
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

    private func makeItem(
        id: String = UUID().uuidString,
        seq: Int = -1,
        format: String = "artracker-screen-v1",
        count: Int = 5,
        duration: Double = 5000.0,
        hasError: Bool = false,
        startTime: String = "2026-11-24T00:00:00.000Z",
        createdAt: Date = Date(),
        data: Data = Data([0x1f, 0x8b, 0x08]), // dummy gzip header
        sessionId: String? = "ses_test",
        held: Bool = true,
        firstTsMs: Int64 = 1000,
        lastTsMs: Int64 = 6000
    ) -> ReplayQueueItem {
        ReplayQueueItem(
            id: id,
            seq: seq,
            format: format,
            count: count,
            duration: duration,
            hasError: hasError,
            hasRage: false,
            startTime: startTime,
            createdAt: createdAt,
            data: data,
            sessionId: sessionId,
            userId: "usr_1",
            held: held,
            firstTsMs: firstTsMs,
            lastTsMs: lastTsMs
        )
    }

    func testHeldChunkIsNotPeekableAndNotPending() {
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let heldItem = makeItem(id: "h1", held: true)
        queue.enqueue(heldItem)

        XCTAssertNil(queue.peekNext())
        XCTAssertEqual(queue.pendingCount(), 0)

        // Enqueue ready item
        let readyItem = makeItem(id: "r1", seq: 0, held: false, firstTsMs: 7000, lastTsMs: 12000)
        queue.enqueue(readyItem)

        XCTAssertEqual(queue.pendingCount(), 1)
        let peeked = queue.peekNext()
        XCTAssertNotNil(peeked)
        XCTAssertEqual(peeked?.id, "r1")
    }

    func testPromoteMakesHeldPeekableWithSeqInFirstTsOrderAndStartFromFirstPromoted() throws {
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        // Make dummy valid ScreenChunkPayload gzipped
        let payload1 = ScreenChunkPayload(seq: -1, frames: [], touches: [])
        let json1 = try JSONEncoder().encode(payload1)
        let data1 = try Gzip.compress(data: json1)

        let payload2 = ScreenChunkPayload(seq: -1, frames: [], touches: [])
        let json2 = try JSONEncoder().encode(payload2)
        let data2 = try Gzip.compress(data: json2)

        let item2 = makeItem(id: "c2", data: data2, sessionId: "ses_A", held: true, firstTsMs: 20_000, lastTsMs: 25_000)
        let item1 = makeItem(id: "c1", data: data1, sessionId: "ses_A", held: true, firstTsMs: 10_000, lastTsMs: 15_000)

        // Enqueue out of order
        queue.enqueue(item2)
        queue.enqueue(item1)

        XCTAssertEqual(queue.pendingCount(), 0)
        XCTAssertNil(queue.peekNext())

        let promoted = queue.promote(sessionId: "ses_A")
        XCTAssertEqual(promoted, 2)
        XCTAssertEqual(queue.pendingCount(), 2)

        let first = queue.peekNext()
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.id, "c1")
        XCTAssertEqual(first?.seq, 0)
        XCTAssertFalse(first?.held ?? true)

        // Verify inside gzipped payload seq was rewritten to 0
        if let gzipped = first?.data, let decomp = try? Gzip.decompress(data: gzipped) {
            let decoded = try JSONDecoder().decode(ScreenChunkPayload.self, from: decomp)
            XCTAssertEqual(decoded.seq, 0)
        } else {
            XCTFail("Failed to decompress promoted item data")
        }

        queue.remove(id: "c1")

        let second = queue.peekNext()
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.id, "c2")
        XCTAssertEqual(second?.seq, 1)
        XCTAssertFalse(second?.held ?? true)
        XCTAssertEqual(second?.startTime, first?.startTime)
    }

    func testHeldTrimmedTo60sWindowByLastTs() {
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let baseDate = Date()

        // 15 chunks with 5s duration each (0..75s)
        for i in 0..<15 {
            let firstTs = Int64(i * 5_000)
            let lastTs = Int64((i + 1) * 5_000)
            let item = makeItem(
                id: "c_\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i)),
                sessionId: "ses_trim",
                held: true,
                firstTsMs: firstTs,
                lastTsMs: lastTs
            )
            queue.enqueue(item)
        }

        // With newest lastTsMs = 75_000, 60s window covers lastTsMs >= 15_000 (i.e. i >= 2)
        // Chunks with lastTsMs < 15_000 (i = 0 [last 5_000], i = 1 [last 10_000]) should be dropped.
        let promoted = queue.promote(sessionId: "ses_trim")
        // Total 15 minus 2 trimmed = 13 remaining
        XCTAssertEqual(promoted, 13)
        XCTAssertEqual(queue.pendingCount(), 13)

        let first = queue.peekNext()
        XCTAssertEqual(first?.id, "c_2")
    }

    func testHeldCappedAt13PerSessionNewestKept() {
        let queue = ReplayDiskQueue(customDirectory: tempDir)
        let baseDate = Date()

        // 20 chunks in quick succession all within 60s window (e.g. 1s apart, lastTs 0..20s)
        for i in 0..<20 {
            let item = makeItem(
                id: "cap_\(i)",
                createdAt: baseDate.addingTimeInterval(Double(i)),
                sessionId: "ses_cap",
                held: true,
                firstTsMs: Int64(i * 1_000),
                lastTsMs: Int64((i + 1) * 1_000)
            )
            queue.enqueue(item)
        }

        let promoted = queue.promote(sessionId: "ses_cap")
        // Cap is 13, so 20 - 7 oldest = 13 kept (indices 7..<20)
        XCTAssertEqual(promoted, 13)
        XCTAssertEqual(queue.pendingCount(), 13)

        let first = queue.peekNext()
        XCTAssertEqual(first?.id, "cap_7")
    }

    func testTrimHeldDoesNotTouchOtherSessionsOrReadyChunksOrPreviousProcessChunks() {
        let queueDate = Date()
        let queue = ReplayDiskQueue(customDirectory: tempDir, dateProvider: { queueDate })

        // 1. Ready chunk (held = false)
        let ready = makeItem(id: "ready_old", seq: 0, createdAt: queueDate.addingTimeInterval(-100), sessionId: "ses_1", held: false, firstTsMs: 0, lastTsMs: 5_000)
        queue.enqueue(ready)

        // 2. Held chunk from previous process run (createdAt < openedAt)
        let previousRunHeld = makeItem(id: "prev_held", createdAt: queueDate.addingTimeInterval(-50), sessionId: "ses_1", held: true, firstTsMs: 1_000, lastTsMs: 6_000)
        queue.enqueue(previousRunHeld)

        // 3. Other session held chunk
        let otherHeld = makeItem(id: "other_held", createdAt: queueDate, sessionId: "ses_other", held: true, firstTsMs: 2_000, lastTsMs: 7_000)
        queue.enqueue(otherHeld)

        // 4. Enqueue 15 chunks in ses_1
        for i in 0..<15 {
            let item = makeItem(
                id: "ses1_\(i)",
                createdAt: queueDate.addingTimeInterval(Double(i)),
                sessionId: "ses_1",
                held: true,
                firstTsMs: Int64(100_000 + i * 5_000),
                lastTsMs: Int64(100_000 + (i + 1) * 5_000)
            )
            queue.enqueue(item)
        }

        // Ready chunk still ready
        XCTAssertEqual(queue.pendingCount(), 1)
        XCTAssertEqual(queue.peekNext()?.id, "ready_old")

        // Previous run held chunk was not trimmed!
        // Other session held was not trimmed!
        let promotedOther = queue.promote(sessionId: "ses_other")
        XCTAssertEqual(promotedOther, 1)

        let promotedSes1 = queue.promote(sessionId: "ses_1")
        // 13 newest from current run + 1 from previous run (createdAt < openedAt not trimmed by trimHeldLocked) = 14
        XCTAssertEqual(promotedSes1, 14)
    }

    func testPromoteHeldBeforeIgnoresSessionId() {
        let cutoff = Date()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let oldS1 = makeItem(id: "old1", createdAt: cutoff.addingTimeInterval(-10), sessionId: "s1", held: true, firstTsMs: 1000, lastTsMs: 5000)
        let oldS2 = makeItem(id: "old2", createdAt: cutoff.addingTimeInterval(-5), sessionId: "s2", held: true, firstTsMs: 2000, lastTsMs: 6000)
        let newS1 = makeItem(id: "new1", createdAt: cutoff.addingTimeInterval(10), sessionId: "s1", held: true, firstTsMs: 3000, lastTsMs: 7000)

        queue.enqueue(oldS1)
        queue.enqueue(oldS2)
        queue.enqueue(newS1)

        let promoted = queue.promoteHeldBefore(cutoff)
        XCTAssertEqual(promoted, 2)
        XCTAssertEqual(queue.pendingCount(), 2)
    }

    func testDropHeldAndDropHeldBeforeDeleteFiles() {
        let cutoff = Date()
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let item1 = makeItem(id: "d1", createdAt: cutoff.addingTimeInterval(-10), sessionId: "s1", held: true)
        let item2 = makeItem(id: "d2", createdAt: cutoff.addingTimeInterval(10), sessionId: "s1", held: true)
        let item3 = makeItem(id: "d3", createdAt: cutoff.addingTimeInterval(10), sessionId: "s2", held: true)

        queue.enqueue(item1)
        queue.enqueue(item2)
        queue.enqueue(item3)

        let droppedBefore = queue.dropHeldBefore(cutoff)
        XCTAssertEqual(droppedBefore, 1)

        let droppedS2 = queue.dropHeld(sessionId: "s2")
        XCTAssertEqual(droppedS2, 1)

        // Only d2 remains
        let promoted = queue.promote(sessionId: "s1")
        XCTAssertEqual(promoted, 1)
        XCTAssertEqual(queue.peekNext()?.id, "d2")
    }

    func testPromotedThenLaterReadyContinuesSeqAndStartMs() {
        let queue = ReplayDiskQueue(customDirectory: tempDir)

        let held1 = makeItem(id: "h1", sessionId: "ses_cont", held: true, firstTsMs: 10_000, lastTsMs: 15_000)
        queue.enqueue(held1)

        _ = queue.promote(sessionId: "ses_cont")
        let peeked1 = queue.peekNext()
        XCTAssertEqual(peeked1?.seq, 0)
        let originalStartTime = peeked1?.startTime

        // Later ready chunk enqueued with seq: -1 (or next)
        let ready1 = makeItem(id: "r1", seq: -1, sessionId: "ses_cont", held: false, firstTsMs: 15_000, lastTsMs: 20_000)
        queue.enqueue(ready1)

        queue.remove(id: "h1")
        let peeked2 = queue.peekNext()
        XCTAssertEqual(peeked2?.id, "r1")
        XCTAssertEqual(peeked2?.seq, 1)
        XCTAssertEqual(peeked2?.startTime, originalStartTime)
    }

    func testLegacyChunkFileWithoutHeldFieldDecodesAsReady() throws {
        // Construct JSON without held, firstTsMs, lastTsMs
        // Swift JSONDecoder default dateEncodingStrategy is deferredToDate (seconds since 2001-01-01 reference date)
        let referenceSeconds = 754128000.0 // 1732435200 - 978307200
        let legacyJson = """
        {
            "id": "legacy_chunk",
            "seq": 0,
            "format": "artracker-screen-v1",
            "count": 3,
            "duration": 5000.0,
            "hasError": false,
            "hasRage": false,
            "startTime": "2026-11-24T00:00:00.000Z",
            "createdAt": \(referenceSeconds),
            "data": "H4sICAAAAAAA/w==",
            "sessionId": "ses_legacy"
        }
        """
        let fileURL = tempDir.appendingPathComponent("legacy.chunk")
        try legacyJson.data(using: .utf8)?.write(to: fileURL)

        let queue = ReplayDiskQueue(customDirectory: tempDir)
        XCTAssertEqual(queue.pendingCount(), 1)
        let item = queue.peekNext()
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "legacy_chunk")
        XCTAssertFalse(item?.held ?? true)
        XCTAssertEqual(item?.firstTsMs, 1732435200000)
        XCTAssertEqual(item?.lastTsMs, 1732435205000)
    }
}
