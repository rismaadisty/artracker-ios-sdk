import XCTest
@testable import ARTracker

final class AppStartItemTests: XCTestCase {
    private func ms(_ milliseconds: UInt64) -> UInt64 {
        milliseconds * 1_000_000
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: iso)!
    }

    private func record(
        type: AppStartType,
        durationMs: Int,
        phases: [(String, Int)],
        firstScreen: String? = nil,
        profiled: Bool = false
    ) -> AppStartRecord {
        AppStartRecord(
            startId: "start_test_uuid_123",
            type: type,
            anchorNs: 0,
            durationMs: durationMs,
            phases: phases.map { AppStartPhase(name: $0.0, ms: $0.1) },
            firstScreen: firstScreen,
            profiled: profiled
        )
    }

    func testItemShape() {
        let item = AppStartItem.make(
            record(type: .cold, durationMs: 1180, phases: [("pre_main", 120), ("first_draw", 1060)], firstScreen: "HomeViewController", profiled: true),
            nowNs: ms(2000),
            now: date("2026-11-19T10:00:02.000Z"),
            sessionId: "ses_1",
            userId: nil,
            build: "217",
            device: AppStartDevice(model: "iPhone15,3", osVersion: "18.1", ramMb: 6144, cores: 6)
        )

        XCTAssertEqual(item.type, .perf)
        XCTAssertEqual(item.name, "app_start")
        XCTAssertEqual(item.timestamp, "2026-11-19T10:00:00.000Z")
        XCTAssertEqual(item.attributes["v"], .number(1))
        XCTAssertEqual(item.attributes["platform"], .string("ios"))
        XCTAssertEqual(item.attributes["type"], .string("cold"))
        XCTAssertEqual(item.attributes["duration_ms"], .number(1180))
        XCTAssertEqual(item.attributes["profiled"], .bool(true))
        XCTAssertEqual(item.attributes["build"], .string("217"))
        XCTAssertEqual(item.attributes["first_screen"], .string("HomeViewController"))
        XCTAssertNil(item.attributes["trampoline"])

        if case .array(let phases) = item.attributes["phases"] {
            XCTAssertEqual(phases.count, 2)
            if case .object(let p0) = phases[0] {
                XCTAssertEqual(p0["name"], .string("pre_main"))
                XCTAssertEqual(p0["ms"], .number(120))
            } else {
                XCTFail("Phase 0 not object")
            }
        } else {
            XCTFail("Phases not array")
        }

        if case .object(let dev) = item.attributes["device"] {
            XCTAssertEqual(dev["model"], .string("iPhone15,3"))
            XCTAssertEqual(dev["os_version"], .string("18.1"))
            XCTAssertEqual(dev["ram_mb"], .number(6144))
            XCTAssertEqual(dev["cores"], .number(6))
        } else {
            XCTFail("Device not object")
        }
    }

    func testMissingValuesOmitted() {
        let item = AppStartItem.make(
            record(type: .warm, durationMs: 300, phases: [("first_draw", 300)], firstScreen: nil, profiled: false),
            nowNs: ms(1000),
            now: date("2026-11-19T10:00:01.000Z"),
            sessionId: nil,
            userId: nil,
            build: nil,
            device: AppStartDevice(model: nil, osVersion: nil, ramMb: nil, cores: nil)
        )

        XCTAssertNil(item.attributes["first_screen"])
        XCTAssertNil(item.attributes["build"])
        XCTAssertNil(item.attributes["trampoline"])
        if case .object(let dev) = item.attributes["device"] {
            XCTAssertTrue(dev.isEmpty)
        } else {
            XCTFail("Device not object")
        }
    }

    func testItemsBufferedBeforeQueueAreEnqueuedAfterPhaseB() {
        let tracker = ARTracker()
        tracker._testResetQueue()
        let item = Item(type: .perf, name: "app_start")
        tracker.enqueueOrBuffer(item)

        let tempDBURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_queue_\(UUID().uuidString).sqlite")
        let q = DiskQueue(databaseURL: tempDBURL)
        defer { try? FileManager.default.removeItem(at: tempDBURL) }

        tracker.drainPendingItems(into: q)
        XCTAssertEqual(q.count(), 1)
    }

    func testBufferCapsAt20() {
        let tracker = ARTracker()
        tracker._testResetQueue()

        for i in 0..<25 {
            let item = Item(type: .perf, name: "app_start_\(i)")
            tracker.enqueueOrBuffer(item)
        }

        let tempDBURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_queue_\(UUID().uuidString).sqlite")
        let q = DiskQueue(databaseURL: tempDBURL)
        defer { try? FileManager.default.removeItem(at: tempDBURL) }

        tracker.drainPendingItems(into: q)
        XCTAssertEqual(q.count(), 20)
    }
}
