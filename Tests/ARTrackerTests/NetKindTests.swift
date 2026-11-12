import XCTest
@testable import ARTracker

final class NetKindTests: XCTestCase {
    func testUnsatisfiedPathIsNone() {
        XCTAssertEqual(
            NetKind.from(satisfied: false, wifi: true, cellular: false, wired: false),
            "none"
        )
    }

    func testInterfaceMapping() {
        XCTAssertEqual(
            NetKind.from(satisfied: true, wifi: true, cellular: false, wired: false),
            "wifi"
        )
        XCTAssertEqual(
            NetKind.from(satisfied: true, wifi: false, cellular: true, wired: false),
            "cellular"
        )
        XCTAssertEqual(
            NetKind.from(satisfied: true, wifi: false, cellular: false, wired: true),
            "ethernet"
        )
        XCTAssertEqual(
            NetKind.from(satisfied: true, wifi: true, cellular: true, wired: false),
            "wifi"
        )
    }

    func testOtherInterfaceOmitsNet() {
        XCTAssertNil(
            NetKind.from(satisfied: true, wifi: false, cellular: false, wired: false)
        )
    }

    func testNetIsNilUntilReachabilityHasPath() {
        let reachability = Reachability()
        XCTAssertNil(reachability.interfaceKind)
    }
}

