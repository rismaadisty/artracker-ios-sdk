import Foundation
#if canImport(UIKit)
import UIKit

/// Intercepts user touches across the app via UIWindow.sendEvent swizzling.
/// Converts touches into MobileTouchPoint events and detects rage taps.
public final class TouchTracker: @unchecked Sendable {
    public static let shared = TouchTracker()

    private let lock = UnfairLock()
    private var isSwizzled: Bool = false
    private var recentTaps: [(point: CGPoint, timestamp: TimeInterval)] = []
    private var onTouchCallback: (@Sendable (CGPoint, Bool) -> Void)?

    private init() {}

    public func start(onTouch: @escaping @Sendable (CGPoint, Bool) -> Void) {
        lock.withLock {
            self.onTouchCallback = onTouch
            guard !isSwizzled else { return }
            isSwizzled = true
            swizzleWindowSendEvent()
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
        guard event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches where touch.phase == .ended {
            let point = touch.location(in: window)
            let now = ProcessInfo.processInfo.systemUptime

            // Detect rage tap: 3+ taps in <= 800ms within radius < 30pt
            let isRageTap = registerTapAndCheckRage(point: point, timestamp: now)

            onTouchCallback?(point, isRageTap)
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
