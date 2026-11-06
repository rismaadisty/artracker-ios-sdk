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
}

