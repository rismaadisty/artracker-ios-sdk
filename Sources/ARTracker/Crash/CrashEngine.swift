import Foundation

public protocol CrashEngine: AnyObject, Sendable {
    func install() throws
    func pendingReportCount() -> Int
    func readPendingReports() throws -> [CrashPayload]
    func purge() throws
}

