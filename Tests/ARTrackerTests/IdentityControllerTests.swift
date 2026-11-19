import XCTest
@testable import ARTracker

final class IdentityControllerTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.identity.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    final class EmitSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [Item] = []

        var items: [Item] {
            lock.withLock { _items }
        }

        func record(_ item: Item) {
            lock.withLock { _items.append(item) }
        }
    }

    func testIdentifyFromAnonymousKeepsSession() {
        let spy = EmitSpy()
        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        let initialSessionId = session.sessionId

        let controller = IdentityController(
            session: session,
            defaults: userDefaults,
            emit: { spy.record($0) }
        )

        controller.identify(userId: "user_alice", traits: ["plan": "pro"])

        let emitted = spy.items
        XCTAssertEqual(emitted.count, 1)

        let identifyItem = emitted[0]
        XCTAssertEqual(identifyItem.type, .event)
        XCTAssertEqual(identifyItem.name, "$identify")
        XCTAssertEqual(identifyItem.sessionId, initialSessionId)
        XCTAssertEqual(identifyItem.userId, "user_alice")
        XCTAssertEqual(identifyItem.attributes["plan"], .string("pro"))
        XCTAssertEqual(session.sessionId, initialSessionId)
        XCTAssertEqual(session.userId, "user_alice")
        XCTAssertEqual(userDefaults.string(forKey: "artracker.user_id"), "user_alice")
    }

    func testUserSwitchOrder() {
        let spy = EmitSpy()
        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        let controller = IdentityController(
            session: session,
            defaults: userDefaults,
            emit: { spy.record($0) }
        )

        controller.identify(userId: "user_alice", traits: [:])
        let sessionA = session.sessionId

        // Now switch to user_bob
        controller.identify(userId: "user_bob", traits: ["tier": "gold"])
        let sessionB = session.sessionId

        XCTAssertNotEqual(sessionA, sessionB)
        let items = spy.items
        // Order:
        // 0: $identify (user_alice, sessionA)
        // 1: session_end (user_alice, sessionA)
        // 2: session_start (user_bob, sessionB)
        // 3: $identify (user_bob, sessionB)
        XCTAssertEqual(items.count, 4)

        let endItem = items[1]
        XCTAssertEqual(endItem.name, "session_end")
        XCTAssertEqual(endItem.userId, "user_alice")
        XCTAssertEqual(endItem.sessionId, sessionA)

        let startItem = items[2]
        XCTAssertEqual(startItem.name, "session_start")
        XCTAssertEqual(startItem.userId, "user_bob")
        XCTAssertEqual(startItem.sessionId, sessionB)
        XCTAssertEqual(startItem.attributes["platform"], .string("ios"))

        let identifyBob = items[3]
        XCTAssertEqual(identifyBob.name, "$identify")
        XCTAssertEqual(identifyBob.userId, "user_bob")
        XCTAssertEqual(identifyBob.sessionId, sessionB)
        XCTAssertEqual(identifyBob.attributes["tier"], .string("gold"))
    }

    func testSameUserSameTraitsEmitsOnce() {
        let spy = EmitSpy()
        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        let controller = IdentityController(
            session: session,
            defaults: userDefaults,
            emit: { spy.record($0) }
        )

        controller.identify(userId: "user_alice", traits: ["plan": "free"])
        controller.identify(userId: "user_alice", traits: ["plan": "free"])
        controller.identify(userId: "user_alice", traits: ["plan": "free"])

        XCTAssertEqual(spy.items.count, 1)

        // Updated traits should emit second $identify
        controller.identify(userId: "user_alice", traits: ["plan": "premium"])
        XCTAssertEqual(spy.items.count, 2)
        XCTAssertEqual(spy.items[1].attributes["plan"], .string("premium"))
    }

    func testResetRotatesAndClears() {
        let spy = EmitSpy()
        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        let controller = IdentityController(
            session: session,
            defaults: userDefaults,
            emit: { spy.record($0) }
        )

        controller.identify(userId: "user_alice", traits: [:])
        let sessionAlice = session.sessionId

        controller.reset()
        let sessionAnon = session.sessionId

        XCTAssertNotEqual(sessionAlice, sessionAnon)
        XCTAssertNil(session.userId)
        XCTAssertNil(userDefaults.string(forKey: "artracker.user_id"))

        let items = spy.items
        // 0: $identify (user_alice)
        // 1: session_end (user_alice, sessionAlice)
        // 2: session_start (nil user, sessionAnon)
        XCTAssertEqual(items.count, 3)

        XCTAssertEqual(items[1].name, "session_end")
        XCTAssertEqual(items[1].userId, "user_alice")
        XCTAssertEqual(items[1].sessionId, sessionAlice)

        XCTAssertEqual(items[2].name, "session_start")
        XCTAssertNil(items[2].userId)
        XCTAssertEqual(items[2].sessionId, sessionAnon)
    }

    func testIdleRotationEmitsSessionStartWithDeviceContext() {
        let spy = EmitSpy()
        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        session.userId = "user_persisted"

        let controller = IdentityController(
            session: session,
            defaults: userDefaults,
            emit: { spy.record($0) }
        )

        controller.sessionDidStart(id: session.sessionId)

        let items = spy.items
        XCTAssertEqual(items.count, 1)
        let start = items[0]
        XCTAssertEqual(start.name, "session_start")
        XCTAssertEqual(start.userId, "user_persisted")
        XCTAssertEqual(start.attributes["platform"], .string("ios"))
        XCTAssertNotNil(start.attributes["model"])
        XCTAssertNotNil(start.attributes["os_version"])
    }

    func testPersistedUserStampsFirstSessionStart() {
        userDefaults.set("user_prior", forKey: "artracker.user_id")
        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        XCTAssertEqual(session.userId, "user_prior")

        let spy = EmitSpy()
        let controller = IdentityController(
            session: session,
            defaults: userDefaults,
            emit: { spy.record($0) }
        )

        controller.sessionDidStart(id: session.sessionId)
        let items = spy.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].userId, "user_prior")
    }

    func testPrePhaseBBufferingDrainsToDiskQueue() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let queue = DiskQueue(databaseURL: tempDir.appendingPathComponent("pre-phase-b.sqlite"))

        let session = SessionManager(clock: { 1000 }, userDefaults: userDefaults)
        let controller = IdentityController(
            session: session,
            defaults: userDefaults
        )

        // Identify called before attachQueue
        controller.identify(userId: "user_buffered", traits: ["foo": "bar"])

        // Disk queue has not received anything yet
        XCTAssertEqual(queue.count(), 0)

        // Attach queue (Phase B complete)
        controller.attachQueue(queue)

        // Now disk queue should have the drained item
        XCTAssertEqual(queue.count(), 1)
        let records = queue.dequeue(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].item.name, "$identify")
        XCTAssertEqual(records[0].item.userId, "user_buffered")
    }
}
