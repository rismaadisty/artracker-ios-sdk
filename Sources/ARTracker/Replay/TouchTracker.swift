import Foundation
#if canImport(UIKit)
import UIKit

/// Intercepts user touches across the app via UIWindow.sendEvent swizzling.
/// Converts touches into ScreenTouchPoint gesture events ("down", "move", "up") and detects rage taps.
public final class TouchTracker: @unchecked Sendable {
    public static let shared = TouchTracker()

    public typealias GestureCallback = @Sendable (_ point: CGPoint, _ kind: String, _ isRageTap: Bool) -> Void

    private let lock = UnfairLock()
    private var isSwizzled: Bool = false
    private var recentTaps: [(point: CGPoint, timestamp: TimeInterval)] = []
    private var onGestureCallback: GestureCallback?

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

    public func start(onGesture: @escaping GestureCallback) {
        lock.withLock {
            self.onGestureCallback = onGesture
            guard !isSwizzled else { return }
            isSwizzled = true
            swizzleWindowSendEvent()
        }
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
        let now = ProcessInfo.processInfo.systemUptime

        let targetWindow = window.windowScene?.windows.first(where: { $0.isKeyWindow }) ?? window

        for touch in touches {
            let pointInTarget = window.convert(touch.location(in: window), to: targetWindow)
            let touchId = ObjectIdentifier(touch)

            switch touch.phase {
            case .began:
                lock.withLock {
                    activeTouches[touchId] = ActiveTouchState(lastPoint: pointInTarget, lastEmittedTime: now)
                }
                onGestureCallback?(pointInTarget, "down", false)

            case .moved:
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
                    onGestureCallback?(pointInTarget, "move", false)
                }

            case .ended:
                lock.withLock {
                    _ = activeTouches.removeValue(forKey: touchId)
                }
                // Detect rage tap: 3+ taps in <= 800ms within radius < 30pt
                let isRageTap = registerTapAndCheckRage(point: pointInTarget, timestamp: now)
                onGestureCallback?(pointInTarget, "up", isRageTap)

            case .cancelled:
                lock.withLock {
                    _ = activeTouches.removeValue(forKey: touchId)
                }
                onGestureCallback?(pointInTarget, "up", false)

            default:
                break
            }
        }

        // Periodic pruning of stale touches (safety guard)
        lock.withLock {
            if activeTouches.count > 10 {
                activeTouches = activeTouches.filter { now - $0.value.lastEmittedTime <= 10.0 }
            }
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
