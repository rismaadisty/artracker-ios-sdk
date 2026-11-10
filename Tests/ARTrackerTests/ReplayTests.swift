import XCTest
@testable import ARTracker

final class ReplayTests: XCTestCase {

    func testMobileChunkPayloadMatchesOfficialContract() throws {
        let tree = MobileViewNode(
            cls: "UIWindow",
            frame: [0, 0, 393, 852],
            children: [
                MobileViewNode(
                    cls: "UILabel",
                    frame: [16, 60, 361, 32],
                    text: "ARTracker iOS Demo"
                ),
                MobileViewNode(
                    cls: "UIButton",
                    frame: [16, 740, 361, 50],
                    text: "Kirim Event Test"
                )
            ]
        )

        let frame = MobileFramePayload(
            ts: 1731143820120,
            screen: "ContentView",
            presentation: "push",
            maskedCount: 0,
            viewTree: tree
        )

        let touch = MobileTouchPoint(
            ts: 1731143822150,
            x: 196.0,
            y: 765.0,
            name: "touch.tap"
        )

        let chunk = MobileChunkPayload(
            format: "artracker-mobile-v1",
            platform: "ios",
            frames: [frame],
            touches: [touch]
        )

        let data = try JSONEncoder().encode(chunk)
        XCTAssertFalse(data.isEmpty)

        // Verify JSON keys match the contract
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["format"] as? String, "artracker-mobile-v1")
        XCTAssertEqual(json?["platform"] as? String, "ios")

        let frames = json?["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.count, 1)
        XCTAssertEqual(frames?[0]["screen"] as? String, "ContentView")
        XCTAssertEqual(frames?[0]["ts"] as? Int64, 1731143820120)

        let touches = json?["touches"] as? [[String: Any]]
        XCTAssertEqual(touches?.count, 1)
        XCTAssertEqual(touches?[0]["x"] as? Double, 196.0)

        // Verify Gzip compression
        let compressed = try Gzip.compress(data: data)
        XCTAssertTrue(Gzip.isGzip(data: compressed))
    }

    func testMaskingRulesExtendedForSensitiveContent() {
        XCTAssertEqual(MaskingRules.maskText("secret123"), "*********")
        XCTAssertEqual(MaskingRules.maskText(""), "")
        XCTAssertEqual(MaskingRules.maskText(nil), "")
    }
}
