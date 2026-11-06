import XCTest
@testable import ARTracker

final class DiskQueueTests: XCTestCase {
    var tempDBURL: URL!
    var queue: DiskQueue!

    override func setUp() {
        super.setUp()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        tempDBURL = tempDir.appendingPathComponent("test_queue_\(UUID().uuidString).sqlite")
        queue = DiskQueue(databaseURL: tempDBURL)
    }

    override func tearDown() {
        queue = nil
        try? FileManager.default.removeItem(at: tempDBURL)
        super.tearDown()
    }

    func testEnqueueAndDequeueFIFO() {
        let item1 = Item(type: .event, name: "event.first")
        let item2 = Item(type: .event, name: "event.second")

        XCTAssertTrue(queue.enqueue(item1))
        XCTAssertTrue(queue.enqueue(item2))
        XCTAssertEqual(queue.count(), 2)

        let records = queue.dequeue(limit: 10)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].item.name, "event.first")
        XCTAssertEqual(records[1].item.name, "event.second")

        queue.delete(ids: [records[0].id])
        XCTAssertEqual(queue.count(), 1)

        let remaining = queue.dequeue(limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].item.name, "event.second")
    }

    func testRetryAndBackoff() {
        let item = Item(type: .event, name: "retry.test")
        XCTAssertTrue(queue.enqueue(item))

        let records = queue.dequeue(limit: 1)
        XCTAssertEqual(records.count, 1)

        // Mark failed with 10s backoff
        queue.markFailed(ids: [records[0].id], backoffSeconds: 10)

        // Immediately dequeue should return empty because next_at is in future
        let empty = queue.dequeue(limit: 1)
        XCTAssertTrue(empty.isEmpty)

        // Count in table is still 1
        XCTAssertEqual(queue.count(), 1)
    }

    func testPurge() {
        _ = queue.enqueue([
            Item(type: .event, name: "a"),
            Item(type: .event, name: "b")
        ])
        XCTAssertEqual(queue.count(), 2)

        queue.purge()
        XCTAssertEqual(queue.count(), 0)
    }
}

