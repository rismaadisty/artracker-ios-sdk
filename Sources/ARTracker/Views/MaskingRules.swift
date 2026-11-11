import Foundation
#if canImport(UIKit)
import UIKit
import ObjectiveC

private var artrackerMaskedKey: UInt8 = 0

extension UIView {
    /// Explicitly mark this view to be masked in Session Replay captures.
    public var artrackerMasked: Bool {
        get {
            (objc_getAssociatedObject(self, &artrackerMaskedKey) as? Bool) ?? false
        }
        set {
            objc_setAssociatedObject(self, &artrackerMaskedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
#endif

public struct MaskingRules: Sendable {
    public static func maskText(_ text: String?) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        return String(repeating: "*", count: min(text.count, 20))
    }

    #if canImport(UIKit)
    public static func shouldMask(view: UIView, maskAllText: Bool) -> Bool {
        if view.artrackerMasked {
            return true
        }

        if maskAllText && (view is UILabel || view is UITextField || view is UITextView) {
            return true
        }

        let clsName = String(describing: type(of: view))

        // When maskAllText is on, mask every SwiftUI hosting area entirely
        if maskAllText && (clsName.contains("HostingView") || clsName.contains("_UIHostingView")) {
            return true
        }

        if let tf = view as? UITextField {
            if tf.isSecureTextEntry { return true }
            if let ct = tf.textContentType {
                if ct == .password || ct == .newPassword || ct == .oneTimeCode || ct == .creditCardNumber {
                    return true
                }
            }
        }

        if let tv = view as? UITextView {
            if let ct = tv.textContentType {
                if ct == .password || ct == .newPassword || ct == .oneTimeCode || ct == .creditCardNumber {
                    return true
                }
            }
        }

        if let id = view.accessibilityIdentifier, id.hasPrefix("mask:") {
            return true
        }

        if clsName.contains("WKWebView") {
            return true
        }

        return false
    }

    /// Recursively collects all masked rectangles within the window in window coordinate space.
    public static func collectMaskRects(in window: UIWindow, maskAllText: Bool) -> [CGRect] {
        var rects: [CGRect] = []

        func traverse(_ view: UIView) {
            guard !view.isHidden && view.alpha > 0.01 else { return }

            if shouldMask(view: view, maskAllText: maskAllText) {
                let rectInWindow = view.convert(view.bounds, to: window)
                let intersection = rectInWindow.intersection(window.bounds)
                if !intersection.isNull && !intersection.isEmpty {
                    rects.append(intersection)
                }
                // Once a view is masked, its children are within its bounds so no need to traverse deeper
                return
            }

            for subview in view.subviews {
                traverse(subview)
            }
        }

        traverse(window)
        return rects
    }

    /// Checks whether the active first responder in the window is considered sensitive.
    public static func isSensitiveFirstResponderActive(in window: UIWindow, maskAllText: Bool) -> Bool {
        var sensitive = false

        func checkFirstResponder(_ view: UIView) {
            if view.isFirstResponder {
                if shouldMask(view: view, maskAllText: maskAllText) {
                    sensitive = true
                    return
                }
            }
            for subview in view.subviews {
                checkFirstResponder(subview)
                if sensitive { return }
            }
        }

        checkFirstResponder(window)
        return sensitive
    }
    #endif
}

