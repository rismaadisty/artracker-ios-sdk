import Foundation
import Darwin

public struct CrashContextData: Codable, Sendable {
    public var sessionId: String
    public var userId: String?
    public var breadcrumbs: [Breadcrumb]

    public init(sessionId: String, userId: String? = nil, breadcrumbs: [Breadcrumb] = []) {
        self.sessionId = sessionId
        self.userId = userId
        self.breadcrumbs = breadcrumbs
    }
}

public final class CrashContextStore: @unchecked Sendable {
    public static let shared = CrashContextStore()

    private let lock = UnfairLock()
    private let magic: UInt32 = 0x41525458 // "ARTX"
    private let mmapSize: Int = 16384 // 16 KB
    private var mappedPointer: UnsafeMutableRawPointer?
    private var fileDescriptor: Int32 = -1
    private var currentData = CrashContextData(sessionId: "")
    private var currentFilePath: String?
    private var previousFilePath: String?

    public init() {}

    deinit {
        cleanup()
    }

    /// Called during Fase B in a background queue.
    public func initialize(inDirectory baseDir: URL? = nil) {
        lock.withLock {
            let dir: URL
            if let base = baseDir {
                dir = base
            } else {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory())
                dir = support.appendingPathComponent("id.art.tracker/crash_context", isDirectory: true)
            }

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let curURL = dir.appendingPathComponent("current_context.bin")
            let prevURL = dir.appendingPathComponent("previous_context.bin")
            self.currentFilePath = curURL.path
            self.previousFilePath = prevURL.path

            // Rotate existing current to previous
            if FileManager.default.fileExists(atPath: curURL.path) {
                try? FileManager.default.removeItem(at: prevURL)
                try? FileManager.default.moveItem(at: curURL, to: prevURL)
            }

            openAndMap(path: curURL.path)
            self.currentData.sessionId = SessionManager.shared.sessionId
            self.currentData.userId = SessionManager.shared.userId
            self.currentData.breadcrumbs = BreadcrumbStore.shared.all()
            syncToMapLocked()
        }
    }

    public func readPreviousContext() -> CrashContextData? {
        lock.withLock {
            guard let prevPath = previousFilePath,
                  FileManager.default.fileExists(atPath: prevPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: prevPath)),
                  data.count >= 8 else {
                return nil
            }

            var fileMagic: UInt32 = 0
            var payloadLen: UInt32 = 0
            data.withUnsafeBytes { raw in
                fileMagic = raw.load(fromByteOffset: 0, as: UInt32.self)
                payloadLen = raw.load(fromByteOffset: 4, as: UInt32.self)
            }

            guard fileMagic == magic,
                  payloadLen > 0,
                  data.count >= Int(8 + payloadLen) else {
                return nil
            }

            let payloadData = data.subdata(in: 8..<Int(8 + payloadLen))
            return try? JSONDecoder().decode(CrashContextData.self, from: payloadData)
        }
    }

    public func purgePreviousContext() {
        lock.withLock {
            if let prevPath = previousFilePath {
                try? FileManager.default.removeItem(atPath: prevPath)
            }
        }
    }

    public func recordSessionId(_ sessionId: String) {
        lock.withLock {
            currentData.sessionId = sessionId
            syncToMapLocked()
        }
    }

    public func recordUserId(_ userId: String?) {
        lock.withLock {
            currentData.userId = userId
            syncToMapLocked()
        }
    }

    public func recordBreadcrumb(_ breadcrumb: Breadcrumb) {
        lock.withLock {
            if currentData.breadcrumbs.count >= 50 {
                currentData.breadcrumbs.removeFirst()
            }
            currentData.breadcrumbs.append(breadcrumb)
            syncToMapLocked()
        }
    }

    private func openAndMap(path: String) {
        cleanup()
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        if ftruncate(fd, off_t(mmapSize)) != 0 {
            close(fd)
            return
        }

        let ptr = mmap(nil, mmapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        if ptr == MAP_FAILED {
            close(fd)
            return
        }

        self.fileDescriptor = fd
        self.mappedPointer = ptr
    }

    private func syncToMapLocked() {
        guard let ptr = mappedPointer else { return }
        guard let encoded = try? JSONEncoder().encode(currentData) else { return }
        let payloadLen = min(encoded.count, mmapSize - 8)

        var m = magic
        var len = UInt32(payloadLen)
        memcpy(ptr, &m, 4)
        memcpy(ptr.advanced(by: 4), &len, 4)
        encoded.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(ptr.advanced(by: 8), base, payloadLen)
            }
        }
    }

    private func cleanup() {
        if let ptr = mappedPointer {
            munmap(ptr, mmapSize)
            mappedPointer = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

