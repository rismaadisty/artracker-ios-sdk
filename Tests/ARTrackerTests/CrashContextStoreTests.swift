import XCTest
@testable import ARTracker

final class CrashContextStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_context_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMmapWriteAndRotateRestore() {
        let store = CrashContextStore()
        store.initialize(inDirectory: tempDir)

        store.recordSessionId("ses_test_1234567890abcdef")
        store.recordUserId("user_alice")
        store.recordBreadcrumb(Breadcrumb(type: "ui", category: "button", message: "Tapped checkout"))

        // Simulate crash / restart:
        // When next launch occurs, initialize rotates current to previous
        let storeNextLaunch = CrashContextStore()
        storeNextLaunch.initialize(inDirectory: tempDir)

        let prev = storeNextLaunch.readPreviousContext()
        XCTAssertNotNil(prev)
        XCTAssertEqual(prev?.sessionId, "ses_test_1234567890abcdef")
        XCTAssertEqual(prev?.userId, "user_alice")
        XCTAssertEqual(prev?.breadcrumbs.count, 1)
        XCTAssertEqual(prev?.breadcrumbs.first?.message, "Tapped checkout")

        storeNextLaunch.purgePreviousContext()
        XCTAssertNil(storeNextLaunch.readPreviousContext())
    }
}

