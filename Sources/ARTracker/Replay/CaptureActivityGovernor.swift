import Foundation

public enum CaptureState: String, Sendable, Equatable {
    case active
    case idle
    case dormant
}

public enum TriggerKind: String, Sendable, Equatable {
    case screen
    case window
    case error
    case network
    case keyboard
    case manual
}

/// Pure Foundation-only governor that tracks user idle states and regulates replay capture rates.
public final class CaptureActivityGovernor: @unchecked Sendable {
    public static let idleFps: Double = 0.2

    private let activeFps: Double
    private let idleAfterMs: Int64
    private let dormantAfterMs: Int64

    private let lock = UnfairLock()
    private var _state: CaptureState = .active
    private var lastUserInputMs: Int64 = 0
    private var lastAdmittedNetworkMs: Int64?

    public init(activeFps: Double, idleAfterMs: Int64 = 30_000, dormantAfterMs: Int64 = 180_000) {
        self.activeFps = activeFps
        self.idleAfterMs = idleAfterMs
        self.dormantAfterMs = dormantAfterMs
    }

    public var state: CaptureState {
        lock.withLock { _state }
    }

    public func onStart(nowMs: Int64) {
        lock.withLock {
            lastUserInputMs = nowMs
            _state = .active
            lastAdmittedNetworkMs = nil
        }
    }

    /// Records user interaction. Returns true if state was transitioned from idle/dormant back to active.
    @discardableResult
    public func onUserInput(nowMs: Int64) -> Bool {
        lock.withLock {
            lastUserInputMs = nowMs
            let wasNotActive = (_state != .active)
            _state = .active
            return wasNotActive
        }
    }

    /// Evaluates current state based on elapsed time since last user input.
    @discardableResult
    public func evaluate(nowMs: Int64) -> CaptureState {
        lock.withLock {
            let elapsed = max(0, nowMs - lastUserInputMs)
            if elapsed >= dormantAfterMs {
                _state = .dormant
            } else if elapsed >= idleAfterMs {
                _state = .idle
            } else {
                _state = .active
            }
            return _state
        }
    }

    /// Returns recommended periodic FPS for the current state (nil for dormant).
    public func periodicFps() -> Double? {
        lock.withLock {
            switch _state {
            case .active:
                return activeFps
            case .idle:
                return Self.idleFps
            case .dormant:
                return nil
            }
        }
    }

    /// True if keyframe generation is allowed (parity with Android contract).
    public var keyframeAllowed: Bool {
        lock.withLock { _state == .active }
    }

    /// Evaluates and admits a trigger. Returns debounce delay in milliseconds, or nil if rejected.
    public func admitTrigger(_ kind: TriggerKind, nowMs: Int64) -> Int64? {
        lock.withLock {
            // Evaluates state at nowMs first
            let elapsed = max(0, nowMs - lastUserInputMs)
            if elapsed >= dormantAfterMs {
                _state = .dormant
            } else if elapsed >= idleAfterMs {
                _state = .idle
            } else {
                _state = .active
            }

            if kind == .network {
                switch _state {
                case .active:
                    lastAdmittedNetworkMs = nowMs
                    return 500
                case .idle:
                    if let last = lastAdmittedNetworkMs, nowMs - last < 5_000 {
                        return nil
                    }
                    lastAdmittedNetworkMs = nowMs
                    return 500
                case .dormant:
                    if let last = lastAdmittedNetworkMs, nowMs - last < 10_000 {
                        return nil
                    }
                    lastAdmittedNetworkMs = nowMs
                    return 500
                }
            }

            switch kind {
            case .manual:
                return 0
            case .screen, .window, .error, .keyboard:
                return 300
            case .network:
                return 500
            }
        }
    }

    /// Calculates wall timestamp in ms of the next state transition, or nil if already dormant.
    public func nextTransitionAtMs() -> Int64? {
        lock.withLock {
            switch _state {
            case .active:
                return lastUserInputMs + idleAfterMs
            case .idle:
                return lastUserInputMs + dormantAfterMs
            case .dormant:
                return nil
            }
        }
    }
}
