import Foundation

public protocol ClockProtocol: Sendable {
    func now() -> Date
    func nowISO8601() -> String
    func systemUptime() -> TimeInterval
}

public final class DefaultClock: ClockProtocol, @unchecked Sendable {
    public static let shared = DefaultClock()

    private let formatter: ISO8601DateFormatter

    public init() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = f
    }

    public func now() -> Date {
        Date()
    }

    public func nowISO8601() -> String {
        formatter.string(from: Date())
    }

    public func format(date: Date) -> String {
        formatter.string(from: date)
    }

    public func systemUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

