import Foundation

public enum AppStartType: String, Sendable, Equatable, Codable {
    case cold
    case warm
    case hot
}

public struct AppStartPhase: Sendable, Equatable, Codable {
    public let name: String
    public let ms: Int

    public init(name: String, ms: Int) {
        self.name = name
        self.ms = ms
    }
}

public struct AppStartRecord: Sendable, Equatable {
    public let startId: String
    public let type: AppStartType
    public let anchorNs: UInt64
    public let durationMs: Int
    public let phases: [AppStartPhase]
    public let firstScreen: String?
    public let profiled: Bool

    public init(
        startId: String,
        type: AppStartType,
        anchorNs: UInt64,
        durationMs: Int,
        phases: [AppStartPhase],
        firstScreen: String?,
        profiled: Bool
    ) {
        self.startId = startId
        self.type = type
        self.anchorNs = anchorNs
        self.durationMs = durationMs
        self.phases = phases
        self.firstScreen = firstScreen
        self.profiled = profiled
    }
}

public enum LaunchContext: Sendable, Equatable {
    case foreground
    case background
    case prewarmed
    case activeAlready
}

public protocol FirstFrameHook: AnyObject, Sendable {
    func await(_ onFrame: @escaping () -> Void)
    func cancel()
}

public final class AppStartTracker {
    public static let lateInitNs: UInt64 = 10_000_000_000
    public static let maxColdNs: UInt64 = 60_000_000_000
    public static let maxWarmHotNs: UInt64 = 10_000_000_000

    private let processStartNs: UInt64?
    private let preMainEndNs: UInt64?
    private let newId: () -> String
    private let onReport: (AppStartRecord) -> Void
    private let onColdAbandoned: () -> Void

    private enum ActiveTracking {
        case cold(anchorNs: UInt64, preMainEndNs: UInt64?, configuredNs: UInt64, didFinishLaunchingNs: UInt64?, didBecomeActiveNs: UInt64?, profiled: Bool)
        case warmPrewarmed(anchorNs: UInt64, didFinishLaunchingNs: UInt64?, didBecomeActiveNs: UInt64?)
        case warmBackground(anchorNs: UInt64, didBecomeActiveNs: UInt64?)
        case hot(anchorNs: UInt64, didBecomeActiveNs: UInt64?)
    }

    private var activeTracking: ActiveTracking?
    private var hasReportedAnyStart = false
    private var isInBackground = false
    private var isColdAbandonedFired = false
    private var _awaitingFirstFrame = false

    public var awaitingFirstFrame: Bool {
        _awaitingFirstFrame
    }

    public var isProfiled: Bool {
        if case .cold(_, _, _, _, _, let profiled) = activeTracking {
            return profiled
        }
        return false
    }

    public init(
        processStartNs: UInt64?,
        preMainEndNs: UInt64?,
        newId: @escaping () -> String = { UUID().uuidString.lowercased() },
        onReport: @escaping (AppStartRecord) -> Void,
        onColdAbandoned: @escaping () -> Void
    ) {
        self.processStartNs = processStartNs
        self.preMainEndNs = preMainEndNs
        self.newId = newId
        self.onReport = onReport
        self.onColdAbandoned = onColdAbandoned
    }

    public convenience init(
        processTimes: ProcessTimes,
        newId: @escaping () -> String = { UUID().uuidString.lowercased() },
        onReport: @escaping (AppStartRecord) -> Void,
        onColdAbandoned: @escaping () -> Void
    ) {
        self.init(
            processStartNs: processTimes.processStartNs,
            preMainEndNs: processTimes.preMainEndNs,
            newId: newId,
            onReport: onReport,
            onColdAbandoned: onColdAbandoned
        )
    }

    public func configured(at ns: UInt64, context: LaunchContext, profiled: Bool) {
        switch context {
        case .activeAlready:
            Log.debug("app_start not reported: app was already active at configure")
            abandonColdIfNeeded(wasProfiled: profiled)
            activeTracking = nil
            _awaitingFirstFrame = false

        case .background:
            isInBackground = true
            abandonColdIfNeeded(wasProfiled: profiled)
            activeTracking = nil
            _awaitingFirstFrame = false

        case .prewarmed:
            abandonColdIfNeeded(wasProfiled: profiled)
            activeTracking = .warmPrewarmed(anchorNs: ns, didFinishLaunchingNs: nil, didBecomeActiveNs: nil)
            _awaitingFirstFrame = false

        case .foreground:
            guard let procStart = processStartNs else {
                Log.debug("app_start not reported: process start time unavailable")
                abandonColdIfNeeded(wasProfiled: profiled)
                activeTracking = nil
                _awaitingFirstFrame = false
                return
            }

            if ns > procStart && (ns - procStart) > Self.lateInitNs {
                Log.debug("app_start not reported: configure called > 10s after process start")
                abandonColdIfNeeded(wasProfiled: profiled)
                activeTracking = nil
                _awaitingFirstFrame = false
                return
            }

            activeTracking = .cold(
                anchorNs: procStart,
                preMainEndNs: preMainEndNs,
                configuredNs: ns,
                didFinishLaunchingNs: nil,
                didBecomeActiveNs: nil,
                profiled: profiled
            )
            _awaitingFirstFrame = false
        }
    }

    public func didFinishLaunching(at ns: UInt64) {
        guard let current = activeTracking else { return }
        switch current {
        case .cold(let anchor, let preMain, let configured, _, let active, let profiled):
            activeTracking = .cold(
                anchorNs: anchor,
                preMainEndNs: preMain,
                configuredNs: configured,
                didFinishLaunchingNs: ns,
                didBecomeActiveNs: active,
                profiled: profiled
            )
        case .warmPrewarmed(let anchor, _, let active):
            activeTracking = .warmPrewarmed(
                anchorNs: anchor,
                didFinishLaunchingNs: ns,
                didBecomeActiveNs: active
            )
        default:
            break
        }
    }

    public func willEnterForeground(at ns: UInt64) {
        isInBackground = false
        _awaitingFirstFrame = false

        if !hasReportedAnyStart {
            // First foreground after being launched in background -> warm
            activeTracking = .warmBackground(anchorNs: ns, didBecomeActiveNs: nil)
        } else {
            // Subsequent foreground after background -> hot
            activeTracking = .hot(anchorNs: ns, didBecomeActiveNs: nil)
        }
    }

    public func didBecomeActive(at ns: UInt64) {
        guard let current = activeTracking else {
            _awaitingFirstFrame = false
            return
        }

        switch current {
        case .cold(let anchor, let preMain, let configured, let didFinish, _, let profiled):
            activeTracking = .cold(
                anchorNs: anchor,
                preMainEndNs: preMain,
                configuredNs: configured,
                didFinishLaunchingNs: didFinish,
                didBecomeActiveNs: ns,
                profiled: profiled
            )
            _awaitingFirstFrame = true

        case .warmPrewarmed(let anchor, let didFinish, _):
            activeTracking = .warmPrewarmed(
                anchorNs: anchor,
                didFinishLaunchingNs: didFinish,
                didBecomeActiveNs: ns
            )
            _awaitingFirstFrame = true

        case .warmBackground(let anchor, _):
            activeTracking = .warmBackground(
                anchorNs: anchor,
                didBecomeActiveNs: ns
            )
            _awaitingFirstFrame = true

        case .hot(let anchor, _):
            activeTracking = .hot(
                anchorNs: anchor,
                didBecomeActiveNs: ns
            )
            _awaitingFirstFrame = true
        }
    }

    public func didEnterBackground(at ns: UInt64) {
        isInBackground = true
        if let current = activeTracking {
            Log.debug("app_start not reported: app entered background before first frame")
            if case .cold(_, _, _, _, _, let profiled) = current {
                abandonColdIfNeeded(wasProfiled: profiled)
            }
            activeTracking = nil
        }
        _awaitingFirstFrame = false
    }

    public func firstFrame(at ns: UInt64, screen: String?) {
        guard _awaitingFirstFrame, let current = activeTracking else { return }
        _awaitingFirstFrame = false
        activeTracking = nil

        switch current {
        case .cold(let anchor, let preMain, let configured, let didFinish, let active, let profiled):
            guard let activeNs = active else { return }
            if ns > anchor && (ns - anchor) > Self.maxColdNs {
                Log.debug("app_start not reported: cold start exceeded 60s")
                abandonColdIfNeeded(wasProfiled: profiled)
                return
            }

            var boundaries: [(name: String, ns: UInt64)] = []
            boundaries.append(("anchor", anchor))
            if let preMainEnd = preMain, preMainEnd > anchor {
                boundaries.append(("pre_main", preMainEnd))
            }
            boundaries.append(("pre_init", configured))
            if let didFinishNs = didFinish, didFinishNs > configured {
                boundaries.append(("did_finish_launching", didFinishNs))
            }
            boundaries.append(("scene_activation", activeNs))
            boundaries.append(("first_draw", ns))

            let record = buildRecord(
                startId: newId(),
                type: .cold,
                anchorNs: anchor,
                endNs: ns,
                boundaries: boundaries,
                screen: screen,
                profiled: profiled
            )
            hasReportedAnyStart = true
            onReport(record)

        case .warmPrewarmed(let anchor, let didFinish, let active):
            guard let activeNs = active else { return }
            if ns > anchor && (ns - anchor) > Self.maxWarmHotNs {
                Log.debug("app_start not reported: warm start exceeded 10s")
                return
            }

            var boundaries: [(name: String, ns: UInt64)] = []
            boundaries.append(("anchor", anchor))
            if let didFinishNs = didFinish, didFinishNs > anchor {
                boundaries.append(("did_finish_launching", didFinishNs))
            }
            boundaries.append(("scene_activation", activeNs))
            boundaries.append(("first_draw", ns))

            let record = buildRecord(
                startId: newId(),
                type: .warm,
                anchorNs: anchor,
                endNs: ns,
                boundaries: boundaries,
                screen: screen,
                profiled: false
            )
            hasReportedAnyStart = true
            onReport(record)

        case .warmBackground(let anchor, let active):
            guard let activeNs = active else { return }
            if ns > anchor && (ns - anchor) > Self.maxWarmHotNs {
                Log.debug("app_start not reported: warm start exceeded 10s")
                return
            }

            let boundaries: [(name: String, ns: UInt64)] = [
                ("anchor", anchor),
                ("foreground_transition", activeNs),
                ("first_draw", ns)
            ]

            let record = buildRecord(
                startId: newId(),
                type: .warm,
                anchorNs: anchor,
                endNs: ns,
                boundaries: boundaries,
                screen: screen,
                profiled: false
            )
            hasReportedAnyStart = true
            onReport(record)

        case .hot(let anchor, let active):
            guard let activeNs = active else { return }
            if ns > anchor && (ns - anchor) > Self.maxWarmHotNs {
                Log.debug("app_start not reported: hot start exceeded 10s")
                return
            }

            let boundaries: [(name: String, ns: UInt64)] = [
                ("anchor", anchor),
                ("foreground_transition", activeNs),
                ("first_draw", ns)
            ]

            let record = buildRecord(
                startId: newId(),
                type: .hot,
                anchorNs: anchor,
                endNs: ns,
                boundaries: boundaries,
                screen: screen,
                profiled: false
            )
            hasReportedAnyStart = true
            onReport(record)
        }
    }

    private func buildRecord(
        startId: String,
        type: AppStartType,
        anchorNs: UInt64,
        endNs: UInt64,
        boundaries: [(name: String, ns: UInt64)],
        screen: String?,
        profiled: Bool
    ) -> AppStartRecord {
        let totalDurationMs = Int((endNs - anchorNs + 500_000) / 1_000_000)

        var msOffsets: [Int] = []
        msOffsets.reserveCapacity(boundaries.count)
        for b in boundaries {
            let offsetMs = b.ns >= anchorNs ? Int((b.ns - anchorNs + 500_000) / 1_000_000) : 0
            msOffsets.append(offsetMs)
        }

        var phases: [AppStartPhase] = []
        for i in 1..<boundaries.count {
            let phaseName = boundaries[i].name
            let phaseDuration = msOffsets[i] - msOffsets[i - 1]
            phases.append(AppStartPhase(name: phaseName, ms: max(0, phaseDuration)))
        }

        return AppStartRecord(
            startId: startId,
            type: type,
            anchorNs: anchorNs,
            durationMs: totalDurationMs,
            phases: phases,
            firstScreen: screen,
            profiled: profiled
        )
    }

    private func abandonColdIfNeeded(wasProfiled: Bool) {
        if wasProfiled && !isColdAbandonedFired {
            isColdAbandonedFired = true
            onColdAbandoned()
        }
    }
}
