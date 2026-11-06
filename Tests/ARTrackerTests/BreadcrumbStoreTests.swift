import XCTest
@testable import ARTracker

final class BreadcrumbStoreTests: XCTestCase {
    func testRollingBufferCapacityEviction() {
        let store = BreadcrumbStore(capacity: 10)
        for i in 1...15 {
            store.add(Breadcrumb(type: "ui", category: "test", message: "Step \(i)"))
        }

        let all = store.all()
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(all.first?.message, "Step 6")
        XCTAssertEqual(all.last?.message, "Step 15")
    }

    func testAsJSONValueConversion() {
        let store = BreadcrumbStore(capacity: 10)
        store.add(Breadcrumb(type: "navigation", category: "screen", message: "Viewed Settings"))

        let jsonVal = store.asJSONValue()
        guard case .array(let items) = jsonVal else {
            XCTFail("Expected array JSONValue")
            return
        }

        XCTAssertEqual(items.count, 1)
        guard case .object(let dict) = items[0] else {
            XCTFail("Expected object in array")
            return
        }

        XCTAssertEqual(dict["type"], .string("navigation"))
        XCTAssertEqual(dict["category"], .string("screen"))
        XCTAssertEqual(dict["message"], .string("Viewed Settings"))
        XCTAssertNotNil(dict["timestamp"])
    }

    func testClearStore() {
        let store = BreadcrumbStore()
        store.add(Breadcrumb(message: "A"))
        XCTAssertEqual(store.all().count, 1)

        store.clear()
        XCTAssertEqual(store.all().count, 0)
    }
}
