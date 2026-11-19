import Foundation
#if canImport(CrashReporter)
import CrashReporter
#endif

public final class PLCrashReporterEngine: CrashEngine, @unchecked Sendable {
    private let lock = UnfairLock()
    #if canImport(CrashReporter)
    private var reporter: PLCrashReporter?
    #endif

    public init() {
        #if canImport(CrashReporter)
        let config = PLCrashReporterConfig(
            signalHandlerType: .mach,
            symbolicationStrategy: []
        )
        self.reporter = PLCrashReporter(configuration: config)
        #endif
    }

    public func install() throws {
        #if canImport(CrashReporter)
        if DebuggerDetector.isAttached {
            Log.info("Debugger (LLDB) is attached. Skipping PLCrashReporter installation to prevent Mach exception SIGTRAP (Signal 5) collision.")
            return
        }
        guard let rep = reporter else {
            throw NSError(domain: "ARTracker.Crash", code: 1, userInfo: [NSLocalizedDescriptionKey: "PLCrashReporter unavailable"])
        }
        try rep.enableAndReturnError()
        #else
        Log.warn("PLCrashReporter not imported")
        #endif
    }

    public func pendingReportCount() -> Int {
        #if canImport(CrashReporter)
        guard let rep = reporter else { return 0 }
        return rep.hasPendingCrashReport() ? 1 : 0
        #else
        return 0
        #endif
    }

    public func readPendingReports() throws -> [CrashPayload] {
        #if canImport(CrashReporter)
        guard let rep = reporter, rep.hasPendingCrashReport() else {
            return []
        }
        let data = try rep.loadPendingCrashReportDataAndReturnError()
        let report = try PLCrashReport(data: data)
        let payload = parse(report: report, rawData: data)
        return [payload]
        #else
        return []
        #endif
    }

    public func purge() throws {
        #if canImport(CrashReporter)
        guard let rep = reporter else { return }
        if rep.hasPendingCrashReport() {
            try rep.purgePendingCrashReportAndReturnError()
        }
        #endif
    }

    internal static func cleanBinaryImageName(_ rawName: String) -> String {
        var name = rawName
        if name.hasSuffix(".debug.dylib") {
            name = String(name.dropLast(".debug.dylib".count))
        } else if name.hasSuffix(".dylib") {
            name = String(name.dropLast(".dylib".count))
        } else if name.hasSuffix(".framework") {
            name = String(name.dropLast(".framework".count))
        }
        return name
    }

    #if canImport(CrashReporter)
    private func parse(report: PLCrashReport, rawData: Data) -> CrashPayload {
        var errorType = "EXC_CRASH"
        var message = "Fatal application crash"

        if let sig = report.signalInfo {
            let sigName = sig.name ?? "SIGNAL"
            errorType = sigName
            let addr = String(format: "0x%llx", sig.address)
            message = "\(sigName) at \(addr)"
        }

        if let exc = report.exceptionInfo {
            let excName = exc.exceptionName ?? errorType
            errorType = excName
            message = "\(excName): \(exc.exceptionReason ?? "")"
        }

        var stackLines: [String] = []
        var crashedThread = "com.apple.main-thread"

        if let threads = report.threads as? [PLCrashReportThreadInfo] {
            for thread in threads {
                if thread.crashed {
                    crashedThread = "Thread \(thread.threadNumber)"
                    if let frames = thread.stackFrames as? [PLCrashReportStackFrameInfo] {
                        for (idx, frame) in frames.prefix(60).enumerated() {
                            let ip = frame.instructionPointer
                            let addr = String(format: "0x%016llx", ip)
                            var imageName = "???"
                            var baseOffsetStr = String(format: "0x0 + %llu", ip)

                            if let img = report.image(forAddress: ip) {
                                let raw = (img.imageName as NSString?)?.lastPathComponent ?? "???"
                                imageName = Self.cleanBinaryImageName(raw)
                                let offset = ip - img.imageBaseAddress
                                baseOffsetStr = String(format: "0x%llx + %llu", img.imageBaseAddress, offset)
                            }

                            stackLines.append("\(idx)   \(imageName)   \(addr)   \(baseOffsetStr)")
                        }
                    }
                }
            }
        }

        var binaryImages: [BinaryImageInfo] = []
        if let images = report.images as? [PLCrashReportBinaryImageInfo] {
            for img in images.prefix(25) {
                let raw = (img.imageName as NSString?)?.lastPathComponent ?? "unknown"
                let name = Self.cleanBinaryImageName(raw)
                let loadAddr = String(format: "0x%016llx", img.imageBaseAddress)
                let uuid = img.imageUUID ?? ""
                binaryImages.append(BinaryImageInfo(uuid: uuid, name: name, loadAddress: loadAddr))
            }
        }

        let timeStr = report.systemInfo?.timestamp.map { DefaultClock.shared.format(date: $0) }
            ?? DefaultClock.shared.nowISO8601()

        return CrashPayload(
            errorType: errorType,
            message: message,
            stackTrace: stackLines.joined(separator: "\n"),
            timestamp: timeStr,
            thread: crashedThread,
            isFatal: true,
            binaryImages: binaryImages,
            rawReportData: rawData
        )
    }
    #endif
}
