import XCTest
@testable import ARTracker

final class RedactorTests: XCTestCase {
    func testSanitizeURLStripsQueryAndFragment() {
        let url = URL(string: "https://api.example.com/v1/users/123/profile?token=secret123&sort=asc#section")!
        let info = Redactor.sanitize(url: url)

        XCTAssertEqual(info.host, "api.example.com")
        XCTAssertEqual(info.path, "/v1/users/123/profile")
        XCTAssertEqual(info.sanitizedURL, "https://api.example.com/v1/users/123/profile")
        XCTAssertFalse(info.sanitizedURL.contains("token"))
        XCTAssertFalse(info.sanitizedURL.contains("secret123"))
    }

    func testSanitizeHeadersRedactsSensitiveValues() {
        let headers: [String: String] = [
            "Authorization": "Bearer super_secret_token",
            "Cookie": "session=abcdef12345",
            "X-Api-Key": "art_live_key_999",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]

        let sanitized = Redactor.sanitizeHeaders(headers)

        XCTAssertEqual(sanitized["Authorization"], "[REDACTED]")
        XCTAssertEqual(sanitized["Cookie"], "[REDACTED]")
        XCTAssertEqual(sanitized["X-Api-Key"], "[REDACTED]")
        XCTAssertEqual(sanitized["Accept"], "application/json")
        XCTAssertEqual(sanitized["Content-Type"], "application/json")
    }

    func testSanitizeNilHeadersReturnsEmpty() {
        let sanitized = Redactor.sanitizeHeaders(nil)
        XCTAssertTrue(sanitized.isEmpty)
    }
}

