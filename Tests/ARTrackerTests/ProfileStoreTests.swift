import XCTest
@testable import ARTracker

final class ProfileStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_profiles_\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveKeepsNewestThree() throws {
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let store = ProfileStore(directory: tempDir, now: { currentTime })

        for i in 1...4 {
            currentTime = currentTime.addingTimeInterval(10)
            let dummyData = "test-\(i)".data(using: .utf8)!
            try store.save(startId: "start_\(i)", body: dummyData)
        }

        let pending = store.pending()
        XCTAssertEqual(pending.count, 3)
        let ids = pending.map(\.startId)
        XCTAssertFalse(ids.contains("start_1"), "Oldest start_1 should have been pruned")
        XCTAssertEqual(ids, ["start_2", "start_3", "start_4"])
    }

    func testPendingPrunesOldAndOverAttemptedFiles() throws {
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let store = ProfileStore(directory: tempDir, now: { currentTime })

        // Save old file (3 days + 1 second ago)
        try store.save(startId: "old_start", body: "old".data(using: .utf8)!)

        // Save fresh file
        currentTime = currentTime.addingTimeInterval(3 * 86400 + 1)
        try store.save(startId: "fresh_start", body: "fresh".data(using: .utf8)!)

        // Old file should be pruned when calling pending()
        var pending = store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.startId, "fresh_start")

        // Now fail fresh_start 5 times
        for _ in 0..<5 {
            if let p = store.pending().first {
                store.markFailed(p)
            }
        }

        // Now attempts >= 5, should be pruned
        pending = store.pending()
        XCTAssertEqual(pending.count, 0)
    }

    func testMarkFailedIncrementsAttempts() throws {
        let currentTime = Date(timeIntervalSince1970: 1_000_000)
        let store = ProfileStore(directory: tempDir, now: { currentTime })

        try store.save(startId: "start_retry", body: "retry".data(using: .utf8)!)
        guard let initial = store.pending().first else {
            XCTFail("Missing pending profile")
            return
        }
        XCTAssertEqual(initial.attempts, 0)

        store.markFailed(initial)

        guard let afterFail = store.pending().first else {
            XCTFail("Missing pending profile after failure")
            return
        }
        XCTAssertEqual(afterFail.attempts, 1)
        XCTAssertEqual(afterFail.startId, "start_retry")
    }
}
