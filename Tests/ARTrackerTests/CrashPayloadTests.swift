import XCTest
@testable import ARTracker

final class CrashPayloadTests: XCTestCase {
    func testCrashPayloadProperties() {
        let binaryImages = [
            BinaryImageInfo(uuid: "8A3F1234", name: "ARTrackerDemo", loadAddress: "0x1029c0000"),
            BinaryImageInfo(uuid: "B45C5678", name: "UIKitCore", loadAddress: "0x180000000")
        ]

        let payload = CrashPayload(
            errorType: "SIGSEGV",
            message: "EXC_BAD_ACCESS at 0x0",
            stackTrace: "0 ARTrackerDemo 0x1029c1234\n1 libsystem_pthread.dylib 0x180123456",
            timestamp: "2026-11-06T12:00:00.000Z",
            thread: "Thread 0 (crashed)",
            isFatal: true,
            binaryImages: binaryImages
        )

        XCTAssertEqual(payload.errorType, "SIGSEGV")
        XCTAssertEqual(payload.message, "EXC_BAD_ACCESS at 0x0")
        XCTAssertTrue(payload.isFatal)
        XCTAssertEqual(payload.binaryImages.count, 2)
        XCTAssertEqual(payload.binaryImages[0].name, "ARTrackerDemo")
        XCTAssertEqual(payload.binaryImages[0].loadAddress, "0x1029c0000")
    }

    func testBinaryImageInfoCodingKeys() throws {
        let img = BinaryImageInfo(uuid: "UUID1", name: "MyLib", loadAddress: "0x1000")
        let data = try JSONEncoder().encode(img)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["uuid"] as? String, "UUID1")
        XCTAssertEqual(json?["name"] as? String, "MyLib")
        XCTAssertEqual(json?["load_address"] as? String, "0x1000")
    }
}

