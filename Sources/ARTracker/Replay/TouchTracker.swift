import Foundation
#if canImport(UIKit)
import UIKit

/// Intercepts user touches across the app via UIWindow.sendEvent swizzling.
/// Converts touches into ScreenTouchPoint gesture events ("down", "move", "up"), detects rage taps,
/// and reports raw user input activity for session lifecycle management.
public final class TouchTracker: @unchecked Sendable {
    public static let shared = TouchTracker()

    public typealias GestureCallback = @Sendable (_ point: CGPoint, _ kind: String, _ isRageTap: Bool) -> Void
    public typealias UserInputCallback = @Sendable () -> Void

    private let lock = UnfairLock()
    private var isSwizzled: Bool = false
    private var recentTaps: [(point: CGPoint, timestamp: TimeInterval)] = []
    private var onGestureCallback: GestureCallback?
    private var onUserInputCallback: UserInputCallback?

    private struct ActiveTouchState {
        var lastPoint: CGPoint
        var lastEmittedTime: TimeInterval
    }
    private var activeTouches: [ObjectIdentifier: ActiveTouchState] = [:]

    // Throttling configuration for drag / scroll moves:
    // Minimum 40ms interval between moves (~25 Hz)
    private let minMoveInterval: TimeInterval = 0.04
    // Minimum displacement to filter out finger jitter (3 points)
    private let minMoveDistanceSquared: CGFloat = 9.0

    private init() {}

    /// Starts always-on activity tracking fired on touch phase `.began`.
    public func startActivityTracking(onUserInput: @escaping UserInputCallback) {
        lock.withLock {
            self.onUserInputCallback = onUserInput
            guard !isSwizzled else { return }
            isSwizzled = true
            swizzleWindowSendEvent()
        }
    }

    /// Sets or removes the session replay gesture handler. Passing nil stops gesture processing.
    public func setGestureHandler(_ handler: GestureCallback?) {
        lock.withLock {
            self.onGestureCallback = handler
            if handler != nil && !isSwizzled {
                isSwizzled = true
                swizzleWindowSendEvent()
            }
        }
    }

    /// Convenience wrapper setting gesture handler and ensuring window event swizzling.
    public func start(onGesture: @escaping GestureCallback) {
        setGestureHandler(onGesture)
    }

    /// Legacy overload for backward compatibility
    public func start(onTouch: @escaping @Sendable (CGPoint, Bool) -> Void) {
        start { point, kind, isRageTap in
            if kind == "up" {
                onTouch(point, isRageTap)
            }
        }
    }

    private func swizzleWindowSendEvent() {
        let originalSelector = #selector(UIWindow.sendEvent(_:))
        let swizzledSelector = #selector(UIWindow.artracker_sendEvent(_:))

        guard let originalMethod = class_getInstanceMethod(UIWindow.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIWindow.self, swizzledSelector) else {
            return
        }

        let didAddMethod = class_addMethod(
            UIWindow.self,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod {
            class_replaceMethod(
                UIWindow.self,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    @MainActor
    fileprivate func handleEvent(_ event: UIEvent, window: UIWindow) {
        guard event.type == .touches, let touches = event.touches(for: window) ?? event.allTouches else { return }

        let (gestureCb, inputCb) = lock.withLock {
            (self.onGestureCallback, self.onUserInputCallback)
        }

        // 120 Hz ProMotion fast-path when replay is off:
        if gestureCb == nil {
            if touches.contains(where: { $0.phase == .began }) {
                inputCb?()
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let targetWindow = window.windowScene?.windows.first(where: { $0.isKeyWindow }) ?? window

        for touch in touches {
            let pointInTarget = window.convert(touch.location(in: window), to: targetWindow)
            let touchId = ObjectIdentifier(touch)

            processSingleTouch(
                phase: touch.phase,
                pointInTarget: pointInTarget,
                touchId: touchId,
                now: now,
                gestureCb: gestureCb,
                inputCb: inputCb
            )
        }

        // Periodic pruning of stale touches (safety guard)
        lock.withLock {
            if activeTouches.count > 10 {
                activeTouches = activeTouches.filter { now - $0.value.lastEmittedTime <= 10.0 }
            }
        }
    }

    @MainActor
    private func processSingleTouch(
        phase: UITouch.Phase,
        pointInTarget: CGPoint,
        touchId: ObjectIdentifier,
        now: TimeInterval,
        gestureCb: GestureCallback?,
        inputCb: UserInputCallback?
    ) {
        switch phase {
        case .began:
            inputCb?()
            lock.withLock {
                activeTouches[touchId] = ActiveTouchState(lastPoint: pointInTarget, lastEmittedTime: now)
            }
            gestureCb?(pointInTarget, "down", false)

        case .moved:
            guard let gestureCb = gestureCb else { return }
            let shouldEmit: Bool = lock.withLock {
                if let state = activeTouches[touchId] {
                    let dt = now - state.lastEmittedTime
                    let dx = pointInTarget.x - state.lastPoint.x
                    let dy = pointInTarget.y - state.lastPoint.y
                    let distSq = dx * dx + dy * dy

                    if dt >= minMoveInterval && distSq >= minMoveDistanceSquared {
                        activeTouches[touchId] = ActiveTouchState(lastPoint: pointInTarget, lastEmittedTime: now)
                        return true
                    }
                    return false
                } else {
                    activeTouches[touchId] = ActiveTouchState(lastPoint: pointInTarget, lastEmittedTime: now)
                    return true
                }
            }

            if shouldEmit {
                gestureCb(pointInTarget, "move", false)
            }

        case .ended:
            lock.withLock {
                _ = activeTouches.removeValue(forKey: touchId)
            }
            guard let gestureCb = gestureCb else { return }
            let isRageTap = registerTapAndCheckRage(point: pointInTarget, timestamp: now)
            gestureCb(pointInTarget, "up", isRageTap)

        case .cancelled:
            lock.withLock {
                _ = activeTouches.removeValue(forKey: touchId)
            }
            gestureCb?(pointInTarget, "up", false)

        default:
            break
        }
    }

    private func registerTapAndCheckRage(point: CGPoint, timestamp: TimeInterval) -> Bool {
        return lock.withLock {
            recentTaps.append((point, timestamp))
            recentTaps = recentTaps.filter { timestamp - $0.timestamp <= 0.8 }

            guard recentTaps.count >= 3 else { return false }

            let closeTaps = recentTaps.filter {
                let dx = $0.point.x - point.x
                let dy = $0.point.y - point.y
                return (dx * dx + dy * dy) <= (30.0 * 30.0)
            }

            if closeTaps.count >= 3 {
                recentTaps.removeAll()
                return true
            }
            return false
        }
    }

    // MARK: - Testing Support

    @MainActor
    internal func simulateTouchForTesting(
        phase: UITouch.Phase,
        point: CGPoint,
        window: UIWindow,
        touchId: ObjectIdentifier = ObjectIdentifier(TouchTracker.self),
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let (gestureCb, inputCb) = lock.withLock {
            (self.onGestureCallback, self.onUserInputCallback)
        }

        if gestureCb == nil {
            if phase == .began {
                inputCb?()
            }
            return
        }

        let targetWindow = window.windowScene?.windows.first(where: { $0.isKeyWindow }) ?? window
        let pointInTarget = window.convert(point, to: targetWindow)

        processSingleTouch(
            phase: phase,
            pointInTarget: pointInTarget,
            touchId: touchId,
            now: now,
            gestureCb: gestureCb,
            inputCb: inputCb
        )
    }
}

#if canImport(UIKit)
extension UIWindow {
    @objc func artracker_sendEvent(_ event: UIEvent) {
        artracker_sendEvent(event)
        TouchTracker.shared.handleEvent(event, window: self)
    }
}
#endif
#endif
