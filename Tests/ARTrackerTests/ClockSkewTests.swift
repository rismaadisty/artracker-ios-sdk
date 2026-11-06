import XCTest
@testable import ARTracker

final class ClockSkewTests: XCTestCase {
    func testISO8601FormattingWithMillisecondPrecision() {
        let clock = DefaultClock()
        let nowString = clock.nowISO8601()

        // e.g. "2026-11-06T12:34:56.789Z"
        let regex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
        let range = NSRange(location: 0, length: nowString.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: nowString, options: [], range: range), "Timestamp \(nowString) must be ISO8601 with 3 fractional second digits")
    }

    func testSystemUptimeIsPositiveAndMonotonic() {
        let clock = DefaultClock()
        let t1 = clock.systemUptime()
        Thread.sleep(forTimeInterval: 0.005)
        let t2 = clock.systemUptime()

        XCTAssertGreaterThan(t1, 0)
        XCTAssertGreaterThanOrEqual(t2, t1)
    }

    func testItemSentAtAndTimestampDriftCalculation() {
        let clock = DefaultClock()
        let pastDate = Date().addingTimeInterval(-86400 * 3) // 3 days ago (offline queue)
        let itemTimestamp = clock.format(date: pastDate)

        let item = Item(
            type: .event,
            name: "offline.event",
            timestamp: itemTimestamp
        )

        let sentAt = clock.nowISO8601()
        let envelope = Envelope(
            sentAt: sentAt,
            context: DeviceContext(
                environment: "production",
                appVersion: "1.0",
                osName: "iOS",
                osVersion: "15.0",
                deviceModel: "iPhone",
                locale: "en_US",
                timezone: "UTC"
            ),
            items: [item]
        )

        // Backend corrects drift: sent_at - timestamp (3 days <= 7 days threshold)
        XCTAssertEqual(envelope.items.first?.timestamp, itemTimestamp)
        XCTAssertEqual(envelope.sentAt, sentAt)
        XCTAssertNotEqual(envelope.sentAt, envelope.items.first?.timestamp)
    }
}

