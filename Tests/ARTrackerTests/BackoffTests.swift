import XCTest
@testable import ARTracker

final class BackoffTests: XCTestCase {
    func testExponentialBackoffProgression() {
        let strategy = BackoffStrategy(baseInterval: 1.0, maxInterval: 300.0, jitterPercentage: 0.0)

        let d0 = strategy.delay(forAttempt: 0)
        let d1 = strategy.delay(forAttempt: 1)
        let d2 = strategy.delay(forAttempt: 2)
        let d3 = strategy.delay(forAttempt: 3)

        XCTAssertEqual(d0, 1.0, accuracy: 0.01)
        XCTAssertEqual(d1, 2.0, accuracy: 0.01)
        XCTAssertEqual(d2, 4.0, accuracy: 0.01)
        XCTAssertEqual(d3, 8.0, accuracy: 0.01)
    }

    func testMaxIntervalCap() {
        let strategy = BackoffStrategy(baseInterval: 1.0, maxInterval: 30.0, jitterPercentage: 0.0)
        let d10 = strategy.delay(forAttempt: 10)
        XCTAssertEqual(d10, 30.0, accuracy: 0.01)
    }

    func testJitterWithinRange() {
        let strategy = BackoffStrategy(baseInterval: 10.0, maxInterval: 300.0, jitterPercentage: 0.2)
        for _ in 0..<20 {
            let delay = strategy.delay(forAttempt: 0) // raw 10.0, jitter +/- 2.0 -> 8.0 to 12.0
            XCTAssertGreaterThanOrEqual(delay, 8.0)
            XCTAssertLessThanOrEqual(delay, 12.0)
        }
    }

    func testParseRetryAfterSeconds() {
        let strategy = BackoffStrategy()
        let parsed = strategy.parseRetryAfter(header: "120")
        XCTAssertEqual(parsed, 120.0)
    }

    func testParseRetryAfterDate() {
        let strategy = BackoffStrategy()
        let futureDate = Date().addingTimeInterval(45)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: futureDate)

        let parsed = strategy.parseRetryAfter(header: header)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!, 45.0, accuracy: 5.0)
    }

    func testParseInvalidRetryAfterReturnsNil() {
        let strategy = BackoffStrategy()
        XCTAssertNil(strategy.parseRetryAfter(header: nil))
        XCTAssertNil(strategy.parseRetryAfter(header: ""))
        XCTAssertNil(strategy.parseRetryAfter(header: "invalid-date-string"))
    }
}

