import Foundation

public struct PendingProfile: Sendable, Equatable {
    public let url: URL
    public let startId: String
    public let createdAt: Date
    public let attempts: Int

    public init(url: URL, startId: String, createdAt: Date, attempts: Int) {
        self.url = url
        self.startId = startId
        self.createdAt = createdAt
        self.attempts = attempts
    }
}

public final class ProfileStore: @unchecked Sendable {
    private let directory: URL
    private let now: () -> Date
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("id.art.tracker/profiles", isDirectory: true),
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.now = now
    }

    public func save(startId: String, body: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let currentDate = now()
        let createdMs = Int64(currentDate.timeIntervalSince1970 * 1000)
        let filename = "\(createdMs)_0_\(startId).json.gz"
        let fileURL = directory.appendingPathComponent(filename)
        try body.write(to: fileURL, options: .atomic)

        pruneToNewestThree()
    }

    public func pending() -> [PendingProfile] {
        lock.lock()
        defer { lock.unlock() }

        let all = loadProfiles()
        let currentDate = now()
        var valid: [PendingProfile] = []

        for p in all {
            let ageSeconds = currentDate.timeIntervalSince(p.createdAt)
            if ageSeconds > (3 * 86400) || p.attempts >= 5 {
                try? fileManager.removeItem(at: p.url)
            } else {
                valid.append(p)
            }
        }

        return valid.sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(_ p: PendingProfile) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: p.url)
    }

    public func markFailed(_ p: PendingProfile) {
        lock.lock()
        defer { lock.unlock() }

        let createdMs = Int64(p.createdAt.timeIntervalSince1970 * 1000)
        let newAttempts = p.attempts + 1
        let newFilename = "\(createdMs)_\(newAttempts)_\(p.startId).json.gz"
        let newURL = directory.appendingPathComponent(newFilename)
        try? fileManager.moveItem(at: p.url, to: newURL)
    }

    private func pruneToNewestThree() {
        let all = loadProfiles()
        let sorted = all.sorted { $0.createdAt > $1.createdAt }
        if sorted.count > 3 {
            for p in sorted.dropFirst(3) {
                try? fileManager.removeItem(at: p.url)
            }
        }
    }

    private func loadProfiles() -> [PendingProfile] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var list: [PendingProfile] = []
        for file in files where file.lastPathComponent.hasSuffix(".json.gz") {
            let name = file.lastPathComponent
            let base = String(name.dropLast(".json.gz".count))
            let parts = base.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let createdMs = Int64(parts[0]),
                  let attempts = Int(parts[1]) else {
                continue
            }
            let startId = String(parts[2])
            let createdAt = Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
            list.append(PendingProfile(url: file, startId: startId, createdAt: createdAt, attempts: attempts))
        }
        return list
    }
}
