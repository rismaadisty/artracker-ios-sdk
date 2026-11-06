import XCTest
@testable import ARTracker

final class MaskingRulesTests: XCTestCase {
    func testMaskTextReplacesCharactersWithStars() {
        let text = "Password123"
        let masked = MaskingRules.maskText(text)
        XCTAssertEqual(masked, "***********")
        XCTAssertEqual(masked.count, text.count)
    }

    func testMaskEmptyOrNilText() {
        XCTAssertEqual(MaskingRules.maskText(nil), "")
        XCTAssertEqual(MaskingRules.maskText(""), "")
    }

    func testMaskTextCapLength() {
        let longText = String(repeating: "A", count: 100)
        let masked = MaskingRules.maskText(longText)
        XCTAssertEqual(masked.count, 20) // capped at 20 stars
    }
}

