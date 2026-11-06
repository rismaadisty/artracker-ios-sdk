import Foundation
import SQLite3

public struct QueueRecord: Sendable {
    public let id: Int64
    public let item: Item
    public let attempts: Int
}

public final class DiskQueue: @unchecked Sendable {
    private let lock = UnfairLock()
    private var db: OpaquePointer?
    private let maxRows: Int = 2000
    private let maxBytes: Int64 = 5 * 1024 * 1024 // 5 MB
    public private(set) var droppedOfflineCount: Int = 0

    public init(databaseURL: URL? = nil) {
        let url: URL
        if let custom = databaseURL {
            url = custom
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = support.appendingPathComponent("id.art.tracker", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("queue.sqlite")
        }

        openDatabase(at: url.path)
        setupSchema()
    }

    deinit {
        lock.withLock {
            if let db = db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    private func openDatabase(at path: String) {
        var dbPtr: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &dbPtr, flags, nil) == SQLITE_OK {
            self.db = dbPtr
            sqlite3_exec(dbPtr, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(dbPtr, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        } else {
            Log.error("Failed to open SQLite database at \(path)")
        }
    }

    private func setupSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS pending(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          payload BLOB NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          next_at INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_pending_next_at ON pending(next_at);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    public func enqueue(_ item: Item) -> Bool {
        enqueue([item]) > 0
    }

    public func enqueue(_ items: [Item]) -> Int {
        guard !items.isEmpty else { return 0 }
        return lock.withLock {
            guard let db = db else { return 0 }
            enforceStorageLimitsLocked()

            let sql = "INSERT INTO pending (payload, attempts, next_at, created_at) VALUES (?, 0, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            var inserted = 0
            let now = Int64(Date().timeIntervalSince1970)

            for item in items {
                guard let data = try? JSONEncoder().encode(item) else { continue }
                sqlite3_reset(stmt)
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 2, now)
                sqlite3_bind_int64(stmt, 3, now)

                if sqlite3_step(stmt) == SQLITE_DONE {
                    inserted += 1
                }
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            return inserted
        }
    }

    public func dequeue(limit: Int) -> [QueueRecord] {
        lock.withLock {
            guard let db = db, limit > 0 else { return [] }
            let now = Int64(Date().timeIntervalSince1970)
            let sql = "SELECT id, payload, attempts FROM pending WHERE next_at <= ? ORDER BY id ASC LIMIT ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, now)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var records: [QueueRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                if let blobPtr = sqlite3_column_blob(stmt, 1) {
                    let blobBytes = sqlite3_column_bytes(stmt, 1)
                    let data = Data(bytes: blobPtr, count: Int(blobBytes))
                    let attempts = Int(sqlite3_column_int(stmt, 2))
                    if let item = try? JSONDecoder().decode(Item.self, from: data) {
                        records.append(QueueRecord(id: id, item: item, attempts: attempts))
                    }
                }
            }
            return records
        }
    }

    public func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            guard let db = db else { return }
            let idList = ids.map { String($0) }.joined(separator: ",")
            let sql = "DELETE FROM pending WHERE id IN (\(idList));"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    public func markFailed(ids: [Int64], backoffSeconds: TimeInterval) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            guard let db = db else { return }
            let nextAt = Int64(Date().timeIntervalSince1970 + backoffSeconds)
            let idList = ids.map { String($0) }.joined(separator: ",")
            let sql = "UPDATE pending SET attempts = attempts + 1, next_at = \(nextAt) WHERE id IN (\(idList));"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    public func count() -> Int {
        lock.withLock {
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pending;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        }
    }

    public func purge() {
        lock.withLock {
            guard let db = db else { return }
            sqlite3_exec(db, "DELETE FROM pending; VACUUM;", nil, nil, nil)
        }
    }

    private func enforceStorageLimitsLocked() {
        guard let db = db else { return }
        // Check row count limit
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pending;", -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let currentCount = Int(sqlite3_column_int(countStmt, 0))
                if currentCount >= maxRows {
                    let toDelete = currentCount - maxRows + 100
                    sqlite3_exec(db, "DELETE FROM pending WHERE id IN (SELECT id FROM pending ORDER BY id ASC LIMIT \(toDelete));", nil, nil, nil)
                    droppedOfflineCount += toDelete
                }
            }
            sqlite3_finalize(countStmt)
        }
    }
}
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
