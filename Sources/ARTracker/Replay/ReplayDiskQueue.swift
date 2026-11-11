import Foundation

/// Item queued for upload representing a compressed chunk.
public struct ReplayQueueItem: Codable, Sendable {
    public let id: String
    public let seq: Int
    public let format: String
    public let count: Int
    public let duration: Double
    public let hasError: Bool
    public let hasRage: Bool
    public let startTime: String
    public let createdAt: Date
    public let data: Data

    public init(
        id: String = UUID().uuidString,
        seq: Int,
        format: String,
        count: Int,
        duration: Double,
        hasError: Bool,
        hasRage: Bool,
        startTime: String,
        createdAt: Date = Date(),
        data: Data
    ) {
        self.id = id
        self.seq = seq
        self.format = format
        self.count = count
        self.duration = duration
        self.hasError = hasError
        self.hasRage = hasRage
        self.startTime = startTime
        self.createdAt = createdAt
        self.data = data
    }
}

/// Persistent offline queue stored in `Library/Caches/ARTracker/replay/` with 50 MB storage cap
/// and rolling 60s byte budget governor.
public final class ReplayDiskQueue: @unchecked Sendable {
    private let lock = UnfairLock()
    private let directoryURL: URL
    private let maxDiskBytes: Int64 = 50 * 1024 * 1024 // 50 MB
    private let maxBytesPerMinute: Int64 = 5 * 1024 * 1024 // 5 MB / min

    // Rolling byte budget tracking: [(timestamp, byteCount)]
    private var rollingByteHistory: [(uptime: TimeInterval, bytes: Int)] = []
    private var consecutiveOverruns: Int = 0

    public init(customDirectory: URL? = nil) {
        if let customDir = customDirectory {
            self.directoryURL = customDir
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directoryURL = caches
                .appendingPathComponent("ARTracker", isDirectory: true)
                .appendingPathComponent("replay", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        pruneDiskUsageIfNeeded()
    }

    // MARK: - Enqueue / Dequeue

    public func enqueue(_ item: ReplayQueueItem) {
        lock.withLock {
            let tsMs = Int64(item.createdAt.timeIntervalSince1970 * 1000.0)
            let filename = String(format: "%014lld_%08d_%@.chunk", tsMs, item.seq, item.id)
            let fileURL = directoryURL.appendingPathComponent(filename)
            do {
                let encoded = try JSONEncoder().encode(item)
                try encoded.write(to: fileURL, options: .atomic)
            } catch {
                // If serialization fails, fallback
            }

            recordBytesLocked(item.data.count)
            pruneDiskUsageLocked()
        }
    }

    public func peekNext() -> ReplayQueueItem? {
        lock.withLock { () -> ReplayQueueItem? in
            guard let files = listChunkFilesLocked(), let first = files.first else {
                return nil
            }
            do {
                let data = try Data(contentsOf: first)
                return try JSONDecoder().decode(ReplayQueueItem.self, from: data)
            } catch {
                try? FileManager.default.removeItem(at: first)
                return nil
            }
        }
    }

    public func remove(id: String) {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return }
            for file in files {
                if file.lastPathComponent.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                    break
                }
            }
        }
    }

    public func clearScreenshotChunks() {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return }
            for file in files {
                if let data = try? Data(contentsOf: file),
                   let item = try? JSONDecoder().decode(ReplayQueueItem.self, from: data),
                   item.format == "artracker-screen-v1" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    public func clearAll() {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Budget Governor

    public func recordBytes(_ count: Int) {
        lock.withLock {
            recordBytesLocked(count)
        }
    }

    private func recordBytesLocked(_ count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        rollingByteHistory.append((uptime: now, bytes: count))
        cleanOldRollingHistoryLocked(now: now)

        let totalRollingBytes = rollingByteHistory.reduce(0) { $0 + $1.bytes }
        if totalRollingBytes > maxBytesPerMinute {
            consecutiveOverruns += 1
        } else if consecutiveOverruns > 0 {
            consecutiveOverruns = 0
        }
    }

    public func shouldHalveFps() -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            cleanOldRollingHistoryLocked(now: now)
            let total = rollingByteHistory.reduce(0) { $0 + $1.bytes }
            return total > maxBytesPerMinute
        }
    }

    public func shouldStepDownQuality() -> Bool {
        lock.withLock {
            return consecutiveOverruns >= 3
        }
    }

    private func cleanOldRollingHistoryLocked(now: TimeInterval) {
        let cutoff = now - 60.0
        rollingByteHistory.removeAll { $0.uptime < cutoff }
    }

    // MARK: - Disk Pruning

    private func pruneDiskUsageIfNeeded() {
        lock.withLock {
            pruneDiskUsageLocked()
        }
    }

    private func pruneDiskUsageLocked() {
        guard let files = listChunkFilesLocked() else { return }
        var totalBytes: Int64 = 0
        var fileSizes: [(url: URL, size: Int64)] = []

        for file in files {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64 {
                totalBytes += size
                fileSizes.append((url: file, size: size))
            }
        }

        // Drop oldest files if exceeding cap
        while totalBytes > maxDiskBytes && !fileSizes.isEmpty {
            let oldest = fileSizes.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            totalBytes -= oldest.size
        }
    }

    private func listChunkFilesLocked() -> [URL]? {
        let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        return files?
            .filter { $0.pathExtension == "chunk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
