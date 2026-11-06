import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

public final class MetricKitSubscriber: NSObject, @unchecked Sendable {
    public static let shared = MetricKitSubscriber()

    private let lock = UnfairLock()
    private var isSubscribed: Bool = false

    public func enable() {
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            lock.withLock {
                guard !isSubscribed else { return }
                isSubscribed = true
                MXMetricManager.shared.add(self)
            }
        }
        #endif
    }

    public func disable() {
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            lock.withLock {
                guard isSubscribed else { return }
                isSubscribed = false
                MXMetricManager.shared.remove(self)
            }
        }
        #endif
    }
}

#if canImport(MetricKit)
@available(iOS 14.0, *)
extension MetricKitSubscriber: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let dict = payload.dictionaryRepresentation()
            Log.info("MetricKit metric payload received with \(dict.count) metrics.")
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashDiagnostics = payload.crashDiagnostics {
                for diag in crashDiagnostics {
                    let treeData = diag.callStackTree.jsonRepresentation()
                    let treeStr = String(data: treeData, encoding: .utf8) ?? ""
                    let item = Item(
                        type: .event,
                        name: "diagnostic.crash_metrickit",
                        sessionId: SessionManager.shared.sessionId,
                        userId: SessionManager.shared.userId,
                        attributes: [
                            "call_stack": .string(String(treeStr.prefix(15_000))),
                            "termination_reason": .string(diag.terminationReason ?? "unknown")
                        ]
                    )
                    ARTracker.shared.enqueueItem(item)
                }
            }

            if let hangDiagnostics = payload.hangDiagnostics {
                for diag in hangDiagnostics {
                    let durationMs = diag.hangDuration.value * 1000.0
                    let treeData = diag.callStackTree.jsonRepresentation()
                    let treeStr = String(data: treeData, encoding: .utf8) ?? ""
                    let item = Item(
                        type: .event,
                        name: "diagnostic.hang",
                        sessionId: SessionManager.shared.sessionId,
                        userId: SessionManager.shared.userId,
                        attributes: [
                            "duration_ms": .number(durationMs),
                            "call_stack": .string(String(treeStr.prefix(15_000)))
                        ]
                    )
                    ARTracker.shared.enqueueItem(item)
                }
            }

            if let cpuDiags = payload.cpuExceptionDiagnostics {
                for diag in cpuDiags {
                    let treeData = diag.callStackTree.jsonRepresentation()
                    let treeStr = String(data: treeData, encoding: .utf8) ?? ""
                    let item = Item(
                        type: .event,
                        name: "diagnostic.cpu_exception",
                        sessionId: SessionManager.shared.sessionId,
                        userId: SessionManager.shared.userId,
                        attributes: [
                            "total_cpu_time": .string(diag.totalCPUTime.description),
                            "call_stack": .string(String(treeStr.prefix(15_000)))
                        ]
                    )
                    ARTracker.shared.enqueueItem(item)
                }
            }

            if let diskDiags = payload.diskWriteExceptionDiagnostics {
                for diag in diskDiags {
                    let treeData = diag.callStackTree.jsonRepresentation()
                    let treeStr = String(data: treeData, encoding: .utf8) ?? ""
                    let item = Item(
                        type: .event,
                        name: "diagnostic.disk_write",
                        sessionId: SessionManager.shared.sessionId,
                        userId: SessionManager.shared.userId,
                        attributes: [
                            "total_writes": .string(diag.totalWritesCaused.description),
                            "call_stack": .string(String(treeStr.prefix(15_000)))
                        ]
                    )
                    ARTracker.shared.enqueueItem(item)
                }
            }
        }
    }
}
#endif
