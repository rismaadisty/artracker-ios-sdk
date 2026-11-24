import Foundation

/// Item queued for upload representing a compressed chunk.
public struct ReplayQueueItem: Codable, Sendable {
    public let id: String
    public var seq: Int
    public let format: String
    public let count: Int
    public var duration: Double
    public let hasError: Bool
    public let hasRage: Bool
    public var startTime: String
    public let createdAt: Date
    public var data: Data
    public let sessionId: String?
    public let userId: String?
    public var held: Bool
    public let firstTsMs: Int64
    public let lastTsMs: Int64

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
        data: Data,
        sessionId: String? = nil,
        userId: String? = nil,
        held: Bool = false,
        firstTsMs: Int64? = nil,
        lastTsMs: Int64? = nil
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
        self.sessionId = sessionId
        self.userId = userId
        self.held = held
        let computedFirst = firstTsMs ?? Int64(createdAt.timeIntervalSince1970 * 1000.0)
        self.firstTsMs = computedFirst
        self.lastTsMs = lastTsMs ?? (computedFirst + Int64(duration))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        seq = try container.decode(Int.self, forKey: .seq)
        format = try container.decode(String.self, forKey: .format)
        count = try container.decode(Int.self, forKey: .count)
        duration = try container.decode(Double.self, forKey: .duration)
        hasError = try container.decode(Bool.self, forKey: .hasError)
        hasRage = try container.decode(Bool.self, forKey: .hasRage)
        startTime = try container.decode(String.self, forKey: .startTime)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        data = try container.decode(Data.self, forKey: .data)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        held = try container.decodeIfPresent(Bool.self, forKey: .held) ?? false

        let fallbackFirst = Int64(createdAt.timeIntervalSince1970 * 1000.0)
        let decodedFirst = try container.decodeIfPresent(Int64.self, forKey: .firstTsMs) ?? fallbackFirst
        firstTsMs = decodedFirst
        lastTsMs = try container.decodeIfPresent(Int64.self, forKey: .lastTsMs) ?? (decodedFirst + Int64(duration))
    }
}

/// Persistent offline queue stored in `Library/Caches/ARTracker/replay/` with 50 MB storage cap,
/// rolling 60s byte budget governor, and held buffer management for error-triggered replays.
public final class ReplayDiskQueue: @unchecked Sendable {
    public static let defaultMaxDiskBytes: Int64 = 50 * 1024 * 1024 // 50 MB
    public static let defaultHeldWindowMs: Int64 = 60_000 // 60 seconds
    public static let defaultMaxHeldPerSession: Int = 13  // 12 x 5s chunks + 1 trigger chunk

    private let lock = UnfairLock()
    private let directoryURL: URL
    private let maxDiskBytes: Int64
    private let maxBytesPerMinute: Int64 = 5 * 1024 * 1024 // 5 MB / min
    private let heldWindowMs: Int64
    private let maxHeldPerSession: Int
    private let openedAt: Date
    private let dateProvider: @Sendable () -> Date

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func iso8601(fromMs ms: Int64) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    // Sequence state per session: (nextSeq, startMs)
    private var sessionSeqState: [String: (nextSeq: Int, startMs: Int64)] = [:]

    // Rolling byte budget tracking: [(timestamp, byteCount)]
    private var rollingByteHistory: [(uptime: TimeInterval, bytes: Int)] = []
    private var consecutiveOverruns: Int = 0

    public init(
        customDirectory: URL? = nil,
        maxDiskBytes: Int64 = ReplayDiskQueue.defaultMaxDiskBytes,
        heldWindowMs: Int64 = ReplayDiskQueue.defaultHeldWindowMs,
        maxHeldPerSession: Int = ReplayDiskQueue.defaultMaxHeldPerSession,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxDiskBytes = maxDiskBytes
        self.heldWindowMs = heldWindowMs
        self.maxHeldPerSession = maxHeldPerSession
        self.dateProvider = dateProvider
        self.openedAt = dateProvider()

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
        loadSessionSeqStateLocked()
        pruneDiskUsageIfNeeded()
    }

    // MARK: - Enqueue / Dequeue

    public func enqueue(_ item: ReplayQueueItem) {
        lock.withLock {
            var finalItem = item
            if finalItem.held {
                finalItem.seq = -1
                writeItemLocked(finalItem)
                trimHeldLocked(sessionId: finalItem.sessionId)
            } else {
                if let sess = finalItem.sessionId {
                    if var state = sessionSeqState[sess] {
                        if finalItem.seq < 0 {
                            finalItem.seq = state.nextSeq
                            state.nextSeq += 1
                            finalItem.startTime = Self.iso8601(fromMs: state.startMs)
                            finalItem.duration = max(100.0, Double(finalItem.lastTsMs - state.startMs))
                            sessionSeqState[sess] = state
                            saveSessionSeqStateLocked()
                        } else {
                            state.nextSeq = max(state.nextSeq, finalItem.seq + 1)
                            sessionSeqState[sess] = state
                            saveSessionSeqStateLocked()
                        }
                    } else if finalItem.seq < 0 {
                        let allocatedSeq = 0
                        finalItem.seq = allocatedSeq
                        let startMs = finalItem.firstTsMs
                        finalItem.startTime = Self.iso8601(fromMs: startMs)
                        finalItem.duration = max(100.0, Double(finalItem.lastTsMs - startMs))
                        sessionSeqState[sess] = (nextSeq: allocatedSeq + 1, startMs: startMs)
                        saveSessionSeqStateLocked()
                    }
                }
                writeItemLocked(finalItem)
            }

            recordBytesLocked(finalItem.data.count)
            pruneDiskUsageLocked()
        }
    }

    public func peekNext() -> ReplayQueueItem? {
        lock.withLock { () -> ReplayQueueItem? in
            guard let files = listChunkFilesLocked() else { return nil }
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    let item = try JSONDecoder().decode(ReplayQueueItem.self, from: data)
                    if !item.held {
                        return item
                    }
                } catch {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            return nil
        }
    }

    public func pendingCount() -> Int {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return 0 }
            var count = 0
            for file in files {
                if let item = readItemAtURL(file), !item.held {
                    count += 1
                }
            }
            return count
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
                if let item = readItemAtURL(file), item.format == "artracker-screen-v1" {
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
            sessionSeqState.removeAll()
            let seqFile = directoryURL.appendingPathComponent("replay_seq.json")
            try? FileManager.default.removeItem(at: seqFile)
        }
    }

    // MARK: - Held Chunk Management & Promotion

    public func promote(sessionId: String) -> Int {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return 0 }
            var heldItems: [(url: URL, item: ReplayQueueItem)] = []
            for file in files {
                if let item = readItemAtURL(file), item.held, item.sessionId == sessionId {
                    heldItems.append((file, item))
                }
            }

            guard !heldItems.isEmpty else { return 0 }
            heldItems.sort {
                if $0.item.firstTsMs != $1.item.firstTsMs {
                    return $0.item.firstTsMs < $1.item.firstTsMs
                }
                return $0.item.createdAt < $1.item.createdAt
            }

            var state = sessionSeqState[sessionId] ?? (nextSeq: 0, startMs: heldItems.first!.item.firstTsMs)
            var promotedCount = 0

            for entry in heldItems {
                var item = entry.item
                let seq = state.nextSeq
                state.nextSeq += 1

                item.held = false
                item.seq = seq
                item.startTime = Self.iso8601(fromMs: state.startMs)
                item.duration = max(100.0, Double(item.lastTsMs - state.startMs))

                // Rewrite seq in payload if possible
                if let decompressed = try? Gzip.decompress(data: item.data),
                   var payload = try? JSONDecoder().decode(ScreenChunkPayload.self, from: decompressed) {
                    payload = ScreenChunkPayload(
                        format: payload.format,
                        platform: payload.platform,
                        seq: seq,
                        frames: payload.frames,
                        touches: payload.touches
                    )
                    if let reencoded = try? JSONEncoder().encode(payload),
                       let regzipped = try? Gzip.compress(data: reencoded) {
                        item.data = regzipped
                    }
                }

                // Delete old file and write with promoted details
                try? FileManager.default.removeItem(at: entry.url)
                writeItemLocked(item)
                promotedCount += 1
            }

            sessionSeqState[sessionId] = state
            saveSessionSeqStateLocked()
            return promotedCount
        }
    }

    public func syncSequence(sessionId: String, nextSeq: Int) {
        lock.withLock {
            if var state = sessionSeqState[sessionId] {
                state.nextSeq = max(state.nextSeq, nextSeq)
                sessionSeqState[sessionId] = state
                saveSessionSeqStateLocked()
            }
        }
    }

    public func nextSequence(sessionId: String) -> Int? {
        lock.withLock {
            sessionSeqState[sessionId]?.nextSeq
        }
    }

    public func promoteHeldBefore(_ cutoff: Date) -> Int {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return 0 }
            var heldItems: [(url: URL, item: ReplayQueueItem)] = []
            for file in files {
                if let item = readItemAtURL(file), item.held, item.createdAt < cutoff {
                    heldItems.append((file, item))
                }
            }

            guard !heldItems.isEmpty else { return 0 }
            heldItems.sort {
                let s0 = $0.item.sessionId ?? ""
                let s1 = $1.item.sessionId ?? ""
                if s0 != s1 {
                    return s0 < s1
                }
                if $0.item.firstTsMs != $1.item.firstTsMs {
                    return $0.item.firstTsMs < $1.item.firstTsMs
                }
                return $0.item.createdAt < $1.item.createdAt
            }

            var promotedCount = 0
            for entry in heldItems {
                var item = entry.item
                let sess = item.sessionId ?? "default_session"
                var state = sessionSeqState[sess] ?? (nextSeq: 0, startMs: item.firstTsMs)

                let seq = state.nextSeq
                state.nextSeq += 1

                item.held = false
                item.seq = seq
                item.startTime = Self.iso8601(fromMs: state.startMs)
                item.duration = max(100.0, Double(item.lastTsMs - state.startMs))

                if let decompressed = try? Gzip.decompress(data: item.data),
                   var payload = try? JSONDecoder().decode(ScreenChunkPayload.self, from: decompressed) {
                    payload = ScreenChunkPayload(
                        format: payload.format,
                        platform: payload.platform,
                        seq: seq,
                        frames: payload.frames,
                        touches: payload.touches
                    )
                    if let reencoded = try? JSONEncoder().encode(payload),
                       let regzipped = try? Gzip.compress(data: reencoded) {
                        item.data = regzipped
                    }
                }

                try? FileManager.default.removeItem(at: entry.url)
                writeItemLocked(item)
                sessionSeqState[sess] = state
                promotedCount += 1
            }

            saveSessionSeqStateLocked()
            return promotedCount
        }
    }

    @discardableResult
    public func dropHeld(sessionId: String) -> Int {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return 0 }
            var count = 0
            for file in files {
                if let item = readItemAtURL(file), item.held, item.sessionId == sessionId {
                    try? FileManager.default.removeItem(at: file)
                    count += 1
                }
            }
            return count
        }
    }

    @discardableResult
    public func dropHeldBefore(_ cutoff: Date) -> Int {
        lock.withLock {
            guard let files = listChunkFilesLocked() else { return 0 }
            var count = 0
            for file in files {
                if let item = readItemAtURL(file), item.held, item.createdAt < cutoff {
                    try? FileManager.default.removeItem(at: file)
                    count += 1
                }
            }
            return count
        }
    }

    private func trimHeldLocked(sessionId: String?) {
        guard let files = listChunkFilesLocked() else { return }
        var sessionHeld: [(url: URL, item: ReplayQueueItem)] = []

        for file in files {
            if let item = readItemAtURL(file),
               item.held,
               item.sessionId == sessionId,
               item.createdAt >= openedAt {
                sessionHeld.append((file, item))
            }
        }

        guard !sessionHeld.isEmpty else { return }

        // 1. Time-based trimming: newest lastTsMs - heldWindowMs
        let newestLastTs = sessionHeld.map { $0.item.lastTsMs }.max() ?? 0
        let cutoffTs = newestLastTs - heldWindowMs

        var remainingHeld: [(url: URL, item: ReplayQueueItem)] = []
        for entry in sessionHeld {
            if entry.item.lastTsMs < cutoffTs {
                try? FileManager.default.removeItem(at: entry.url)
            } else {
                remainingHeld.append(entry)
            }
        }

        // 2. Count-based trimming: keep newest maxHeldPerSession
        if remainingHeld.count > maxHeldPerSession {
            remainingHeld.sort {
                if $0.item.firstTsMs != $1.item.firstTsMs {
                    return $0.item.firstTsMs < $1.item.firstTsMs
                }
                return $0.item.createdAt < $1.item.createdAt
            }
            let excess = remainingHeld.count - maxHeldPerSession
            for i in 0..<excess {
                try? FileManager.default.removeItem(at: remainingHeld[i].url)
            }
        }
    }

    // MARK: - Helper File Operations

    private func writeItemLocked(_ item: ReplayQueueItem) {
        let tsMs = Int64(item.createdAt.timeIntervalSince1970 * 1000.0)
        let seqField = item.held ? -1 : item.seq
        let filename = String(format: "%014lld_%08d_%@.chunk", tsMs, seqField, item.id)
        let fileURL = directoryURL.appendingPathComponent(filename)
        do {
            let encoded = try JSONEncoder().encode(item)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Write failed
        }
    }

    private func readItemAtURL(_ url: URL) -> ReplayQueueItem? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ReplayQueueItem.self, from: data)
        } catch {
            return nil
        }
    }

    private struct SeqStateStorage: Codable {
        let nextSeq: Int
        let startMs: Int64
    }

    private func saveSessionSeqStateLocked() {
        var codableMap: [String: SeqStateStorage] = [:]
        for (k, v) in sessionSeqState {
            codableMap[k] = SeqStateStorage(nextSeq: v.nextSeq, startMs: v.startMs)
        }
        let seqFile = directoryURL.appendingPathComponent("replay_seq.json")
        if let data = try? JSONEncoder().encode(codableMap) {
            try? data.write(to: seqFile, options: .atomic)
        }
    }

    private func loadSessionSeqStateLocked() {
        let seqFile = directoryURL.appendingPathComponent("replay_seq.json")
        guard let data = try? Data(contentsOf: seqFile),
              let codableMap = try? JSONDecoder().decode([String: SeqStateStorage].self, from: data) else {
            return
        }
        for (k, v) in codableMap {
            sessionSeqState[k] = (nextSeq: v.nextSeq, startMs: v.startMs)
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
