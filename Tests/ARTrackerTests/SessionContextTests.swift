import XCTest
@testable import ARTracker

final class SessionContextTests: XCTestCase {
    func testStartAttributesContainContractKeys() {
        let attrs = SessionContext.startAttributes(
            config: ARTrackerConfig(environment: "test"),
            launchType: "cold",
            sessionId: "ses_test123"
        )

        let requiredKeys = [
            "platform",
            "os_version",
            "manufacturer",
            "model",
            "app_version",
            "app_build",
            "locale",
            "tz",
            "network",
            "is_emulator",
            "sdk_version",
            "session_id",
            "launch_type"
        ]

        for k in requiredKeys {
            XCTAssertNotNil(attrs[k], "Missing key: \(k)")
        }

        XCTAssertEqual(attrs["platform"], .string("ios"))
        XCTAssertEqual(attrs["manufacturer"], .string("Apple"))
        XCTAssertEqual(attrs["session_id"], .string("ses_test123"))
        XCTAssertEqual(attrs["launch_type"], .string("cold"))
        XCTAssertEqual(attrs["sdk_version"], .string(SDKInfo.current.version))
    }

    func testOsVersionIsNumeric() {
        let attrs = SessionContext.startAttributes(sessionId: "ses_123")
        guard case .string(let osVer) = attrs["os_version"] else {
            XCTFail("os_version should be string")
            return
        }

        let regex = try! NSRegularExpression(pattern: #"^\d+(\.\d+){1,2}$"#)
        let range = NSRange(location: 0, length: osVer.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: osVer, range: range), "os_version '\(osVer)' does not match numeric version format")
    }

    func testLocaleIsBCP47() {
        let attrs = SessionContext.startAttributes(sessionId: "ses_123")
        guard case .string(let locale) = attrs["locale"] else {
            XCTFail("locale should be string")
            return
        }

        XCTAssertFalse(locale.contains("_"), "locale '\(locale)' should use hyphen instead of underscore (BCP-47)")
    }

    func testLaunchTypePreservedIfProvided() {
        let attrsWithoutLaunch = SessionContext.startAttributes(sessionId: "ses_123")
        XCTAssertNil(attrsWithoutLaunch["launch_type"])

        let attrsRotation = SessionContext.startAttributes(launchType: "rotation", sessionId: "ses_123")
        XCTAssertEqual(attrsRotation["launch_type"], .string("rotation"))
    }
}
