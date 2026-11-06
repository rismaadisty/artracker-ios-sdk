import Foundation

public struct BackoffStrategy: Sendable {
    public let baseInterval: TimeInterval
    public let maxInterval: TimeInterval
    public let jitterPercentage: Double

    public init(
        baseInterval: TimeInterval = 1.0,
        maxInterval: TimeInterval = 300.0,
        jitterPercentage: Double = 0.2
    ) {
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
        self.jitterPercentage = jitterPercentage
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exp = min(Double(attempt), 10.0)
        let raw = min(baseInterval * pow(2.0, exp), maxInterval)
        let jitterRange = raw * jitterPercentage
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(0.5, raw + jitter)
    }

    public func parseRetryAfter(header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }
        if let seconds = Double(header), seconds >= 0 {
            return min(seconds, maxInterval)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            let interval = date.timeIntervalSinceNow
            return max(0.0, min(interval, maxInterval))
        }
        return nil
    }
}

