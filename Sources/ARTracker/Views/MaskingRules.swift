import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct MaskingRules: Sendable {
    public static func maskText(_ text: String?) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        return String(repeating: "*", count: min(text.count, 20))
    }

    #if canImport(UIKit)
    public static func shouldMask(view: UIView, maskAllText: Bool) -> Bool {
        if maskAllText && (view is UILabel || view is UITextField || view is UITextView) {
            return true
        }

        if let tf = view as? UITextField, tf.isSecureTextEntry {
            return true
        }

        if let id = view.accessibilityIdentifier, id.hasPrefix("mask:") {
            return true
        }

        let clsName = String(describing: type(of: view))
        if clsName.contains("WKWebView") {
            return true
        }

        return false
    }
    #endif
}

