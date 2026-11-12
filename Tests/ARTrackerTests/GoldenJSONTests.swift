import XCTest
@testable import ARTracker

final class GoldenJSONTests: XCTestCase {
    func testEnvelopeStructureMatchesBackendSchema() throws {
        let context = DeviceContext(
            environment: "production",
            appVersion: "1.4.0 (217)",
            osName: "iOS",
            osVersion: "26.4",
            deviceModel: "iPhone15,3",
            locale: "id_ID",
            timezone: "Asia/Jakarta"
        )

        let crashItem = Item(
            id: "itm_0123456789abcdef",
            type: .log,
            name: "crash",
            level: .fatal,
            message: "EXC_BAD_ACCESS (SIGSEGV)",
            timestamp: "2026-11-05T10:12:03.412Z",
            sessionId: "ses_9f3a1c7b2d4e6f8a0b1c2d3e",
            userId: "u_1029",
            attributes: [
                "stack_trace": .string("0 ARTrackerDemo 0x102a4f1c8"),
                "is_fatal": .bool(true),
                "error_type": .string("SIGSEGV")
            ]
        )

        let envelope = Envelope(
            sentAt: "2026-11-05T10:14:00.120Z",
            sdk: SDKInfo(name: "artracker-ios", version: "0.1.0"),
            context: context,
            items: [crashItem]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?["sent_at"] as? String, "2026-11-05T10:14:00.120Z")

        let sdk = jsonObject?["sdk"] as? [String: Any]
        XCTAssertEqual(sdk?["name"] as? String, "artracker-ios")
        XCTAssertEqual(sdk?["version"] as? String, "0.1.0")

        let ctx = jsonObject?["context"] as? [String: Any]
        XCTAssertEqual(ctx?["environment"] as? String, "production")
        XCTAssertEqual(ctx?["app_version"] as? String, "1.4.0 (217)")
        XCTAssertEqual(ctx?["os_name"] as? String, "iOS")

        let items = jsonObject?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 1)

        let first = items?.first
        XCTAssertEqual(first?["id"] as? String, "itm_0123456789abcdef")
        XCTAssertEqual(first?["type"] as? String, "log")
        XCTAssertEqual(first?["level"] as? String, "fatal")
        XCTAssertEqual(first?["name"] as? String, "crash")
        XCTAssertEqual(first?["session_id"] as? String, "ses_9f3a1c7b2d4e6f8a0b1c2d3e")
        XCTAssertEqual(first?["user_id"] as? String, "u_1029")

        let attrs = first?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["is_fatal"] as? Bool, true)
        XCTAssertEqual(attrs?["error_type"] as? String, "SIGSEGV")
    }

    func testItemFieldLimitsAndSanitization() {
        let longName = String(repeating: "A", count: 500)
        let longMessage = String(repeating: "M", count: 10000)
        let longId = String(repeating: "I", count: 200)

        let item = Item(
            id: longId,
            type: .event,
            name: longName,
            message: longMessage,
            sessionId: longId,
            userId: longId
        )

        XCTAssertEqual(item.name.count, 255)
        XCTAssertEqual(item.message?.count, 4096)
        XCTAssertEqual(item.id.count, 128)
        XCTAssertEqual(item.sessionId?.count, 128)
        XCTAssertEqual(item.userId?.count, 128)
    }

    func testAttributeCapEnforcement() throws {
        // Build 50KB string attribute
        let hugeString = String(repeating: "X", count: 50_000)
        let item = Item(
            type: .log,
            name: "test",
            attributes: [
                "stack_trace": .string(hugeString),
                "normal": .string("hello")
            ]
        )

        let encoded = try JSONEncoder().encode(item.attributes)
        XCTAssertLessThanOrEqual(encoded.count, 32_768, "Attributes must not exceed backend 32KB hard limit")
    }

    func testPerfSamplesItemMatchesWireContract() throws {
        final class State: @unchecked Sendable {
            var cpuMs: Double = 0
            var uptimeMs: Double = 1000
            var nowMs: Int64 = 1_731_300_000_000
            var items: [Item] = []
        }
        let state = State()
        let queue = DispatchQueue(label: "test.golden.perf")

        let probe = ProcessProbe(
            cpuTimeMs: {
                let current = state.cpuMs
                state.cpuMs += 1500 // next sample: 1500ms / (1000ms * 6 cores) * 100 = 25%
                return current
            },
            threadCount: { 14 },
            footprintBytes: { 209_715_200 },
            thermal: { .nominal },
            ramFreeMb: { 2048 },
            storageFreeMb: { 98_304 },
            net: { "wifi" },
            cores: 6
        )
        let sampler = PerfSampler(
            probe: probe,
            frames: nil,
            nowMs: {
                let t = state.nowMs
                state.nowMs += 1000
                return t
            },
            uptimeMs: {
                let u = state.uptimeMs
                state.uptimeMs += 1000
                return u
            }
        )
        let monitor = PerfMonitor(
            sampler: sampler,
            intervalMs: 1000,
            device: {
                PerfDevice(
                    ramMb: 6144,
                    storageMb: 244_140,
                    osVersion: "26.4",
                    cores: 6,
                    refreshHz: 120
                )
            },
            sessionId: { "ses_golden123" },
            userId: { nil },
            enqueue: { state.items.append($0) },
            queue: queue
        )

        monitor.tick()
        monitor.tick()
        monitor.flush()

        XCTAssertEqual(state.items.count, 1)
        let item = try XCTUnwrap(state.items.first)

        let data = try JSONEncoder().encode(item)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "perf")
        XCTAssertEqual(json["name"] as? String, "perf.samples")
        XCTAssertEqual(json["session_id"] as? String, "ses_golden123")
        XCTAssertEqual(json["timestamp"] as? String, "2024-11-11T04:40:00.000Z")

        let attrs = try XCTUnwrap(json["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["v"] as? Int, 1)
        XCTAssertEqual(attrs["platform"] as? String, "ios")
        XCTAssertEqual(attrs["interval_ms"] as? Int, 1000)

        let device = try XCTUnwrap(attrs["device"] as? [String: Any])
        XCTAssertEqual(device["os_version"] as? String, "26.4")
        XCTAssertEqual(device["ram_mb"] as? Int, 6144)
        XCTAssertEqual(device["storage_mb"] as? Int, 244_140)
        XCTAssertEqual(device["cores"] as? Int, 6)
        XCTAssertEqual(device["refresh_hz"] as? Int, 120)

        let samples = try XCTUnwrap(attrs["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 2)
        XCTAssertNil(samples[0]["cpu"])
        XCTAssertEqual(samples[1]["cpu"] as? Int, 25)
        XCTAssertEqual(samples[1]["mem_mb"] as? Int, 200)
        XCTAssertEqual(samples[1]["threads"] as? Int, 14)
        XCTAssertEqual(samples[1]["thermal"] as? String, "nominal")
        XCTAssertEqual(samples[1]["ram_free_mb"] as? Int, 2048)
        XCTAssertEqual(samples[1]["storage_free_mb"] as? Int, 98_304)
        XCTAssertEqual(samples[1]["net"] as? String, "wifi")
        XCTAssertNil(samples[1]["battery"])
        XCTAssertFalse(samples[1].values.contains { $0 is NSNull })
    }
}

