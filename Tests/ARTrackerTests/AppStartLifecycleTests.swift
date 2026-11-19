import XCTest
@testable import ARTracker
import ARTrackerNative
#if canImport(UIKit)
import UIKit

private final class FakeFirstFrameHook: FirstFrameHook, @unchecked Sendable {
    var onFrame: (() -> Void)?
    var isCancelled: Bool = false
    var awaitCalledCount: Int = 0

    func await(_ onFrame: @escaping () -> Void) {
        isCancelled = false
        awaitCalledCount += 1
        self.onFrame = onFrame
    }

    func cancel() {
        isCancelled = true
        onFrame = nil
    }

    func fire() {
        let callback = onFrame
        onFrame = nil
        callback?()
    }
}

class FakeHomeViewController: UIViewController {}

final class AppStartLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_app_start_lifecycle_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    func testLaunchContextMapping() {
        // Priority 1: .active wins over ActivePrewarm=1
        let ctx1 = AppStartObserver.launchContext(appState: .active, environment: ["ActivePrewarm": "1"])
        XCTAssertEqual(ctx1, .activeAlready)

        // Priority 2: ActivePrewarm=1 when not active
        let ctx2 = AppStartObserver.launchContext(appState: .inactive, environment: ["ActivePrewarm": "1"])
        XCTAssertEqual(ctx2, .prewarmed)

        // Priority 3: .background
        let ctx3 = AppStartObserver.launchContext(appState: .background, environment: [:])
        XCTAssertEqual(ctx3, .background)

        // Priority 4: foreground (inactive with no prewarm)
        let ctx4 = AppStartObserver.launchContext(appState: .inactive, environment: [:])
        XCTAssertEqual(ctx4, .foreground)
    }

    @MainActor
    func testDisabledTrackingCreatesNothing() {
        let tracker = ARTracker()
        var config = ARTrackerConfig()
        config.enableAppStartTracking = false

        tracker._testStartAppStartTracking(config: config)
        XCTAssertNil(tracker.appStartTrackerForTesting)
    }

    @MainActor
    func testProfilingDecisionUsesRate() {
        let tracker1 = ARTracker()
        var cfg1 = ARTrackerConfig()
        cfg1.enableStartupProfiling = true
        cfg1.startupProfileSampleRate = 0.1

        // random 0.05 < 0.1 -> profiled
        tracker1._testStartAppStartTracking(config: cfg1, random: { 0.05 }, launchContext: .foreground)
        XCTAssertTrue(tracker1.appStartTrackerForTesting?.isProfiled ?? false)

        let tracker2 = ARTracker()
        var cfg2 = ARTrackerConfig()
        cfg2.enableStartupProfiling = true
        cfg2.startupProfileSampleRate = 0.1

        // random 0.50 >= 0.1 -> not profiled
        tracker2._testStartAppStartTracking(config: cfg2, random: { 0.50 }, launchContext: .foreground)
        XCTAssertFalse(tracker2.appStartTrackerForTesting?.isProfiled ?? true)
    }

    @MainActor
    func testFirstFrameAfterBecomeActiveEnqueuesAppStart() {
        let tracker = ARTracker()
        tracker._testResetQueue()
        let fakeHook = FakeFirstFrameHook()
        let cfg = ARTrackerConfig()

        let dbURL = tempDir.appendingPathComponent("q.sqlite")
        let diskQueue = DiskQueue(databaseURL: dbURL)

        let baseNs = artn_now_ns()
        let times = ProcessTimes(processStartNs: baseNs - 50_000_000, preMainEndNs: baseNs - 20_000_000)

        tracker._testStartAppStartTracking(
            config: cfg,
            frameHook: fakeHook,
            launchContext: .foreground,
            processTimes: times
        )
        tracker.drainPendingItems(into: diskQueue)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(fakeHook.awaitCalledCount, 1)

        fakeHook.fire()

        tracker.drainPendingItems(into: diskQueue)
        XCTAssertEqual(diskQueue.count(), 1)
        let item = diskQueue.dequeue(limit: 1).first?.item
        XCTAssertEqual(item?.name, "app_start")
    }

    @MainActor
    func testBackgroundCancelsPendingFrameHook() {
        let tracker = ARTracker()
        let fakeHook = FakeFirstFrameHook()
        let cfg = ARTrackerConfig()

        let baseNs = artn_now_ns()
        let times = ProcessTimes(processStartNs: baseNs - 50_000_000, preMainEndNs: baseNs - 20_000_000)

        tracker._testStartAppStartTracking(
            config: cfg,
            frameHook: fakeHook,
            launchContext: .foreground,
            processTimes: times
        )

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(fakeHook.isCancelled)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(fakeHook.isCancelled)
    }

    @MainActor
    func testBackgroundBeforeFrameDiscardsProfile() {
        let tracker = ARTracker()
        tracker._testResetQueue()
        let fakeHook = FakeFirstFrameHook()
        var cfg = ARTrackerConfig()
        cfg.enableStartupProfiling = true
        cfg.startupProfileSampleRate = 1.0

        let profileStoreDir = tempDir.appendingPathComponent("profiles")
        let store = ProfileStore(directory: profileStoreDir)

        let baseNs = artn_now_ns()
        let times = ProcessTimes(processStartNs: baseNs - 50_000_000, preMainEndNs: baseNs - 20_000_000)

        tracker._testStartAppStartTracking(
            config: cfg,
            random: { 0.0 },
            frameHook: fakeHook,
            profileStore: store,
            launchContext: .foreground,
            processTimes: times
        )

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        let exp = expectation(description: "Wait utility queue")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(store.pending().count, 0)
    }

    @MainActor
    func testProfiledColdWritesOneProfileFile() {
        let tracker = ARTracker()
        tracker._testResetQueue()
        let fakeHook = FakeFirstFrameHook()
        var cfg = ARTrackerConfig()
        cfg.enableStartupProfiling = true
        cfg.startupProfileSampleRate = 1.0

        let profileStoreDir = tempDir.appendingPathComponent("profiles")
        let store = ProfileStore(directory: profileStoreDir)
        let dbURL = tempDir.appendingPathComponent("q.sqlite")
        let diskQueue = DiskQueue(databaseURL: dbURL)

        let baseNs = artn_now_ns()
        let times = ProcessTimes(processStartNs: baseNs - 50_000_000, preMainEndNs: baseNs - 20_000_000)

        tracker._testStartAppStartTracking(
            config: cfg,
            random: { 0.0 },
            frameHook: fakeHook,
            profileStore: store,
            launchContext: .foreground,
            processTimes: times
        )

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fakeHook.fire()

        tracker.drainPendingItems(into: diskQueue)
        let items = diskQueue.dequeue(limit: 1)
        XCTAssertEqual(items.count, 1)
        let appStartItem = items[0].item

        let exp = expectation(description: "Profile saved to store")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        let pending = store.pending()
        XCTAssertEqual(pending.count, 1)
        if case .string(let startId) = appStartItem.attributes["start_id"] {
            XCTAssertEqual(pending.first?.startId, startId)
        } else {
            XCTFail("Missing start_id on app_start item")
        }
    }

    @MainActor
    func testTopScreenNameStripsModule() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let rootVC = FakeHomeViewController()
        let nav = UINavigationController(rootViewController: rootVC)
        window.rootViewController = nav
        window.makeKeyAndVisible()

        let name = AppStartObserver.topScreenName(window: window)
        XCTAssertEqual(name, "FakeHomeViewController")
    }
}
#endif
