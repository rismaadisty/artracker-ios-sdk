import Foundation
#if canImport(UIKit)
import UIKit

/// Stage 1 of 2-Stage Pipeline: Fast primitive view-tree extraction on @MainActor (< 1.5ms).
/// Recursively captures the native view hierarchy (UIKit & SwiftUI) into a MobileViewNode tree.
public final class WireframeCrawler: @unchecked Sendable {
    public static let shared = WireframeCrawler()

    private init() {}

    @MainActor
    public func captureWindowTree(
        window: UIWindow,
        maskAllText: Bool
    ) -> (tree: MobileViewNode, maskedCount: Int) {
        var nodeCount = 0
        var maskedCount = 0
        let maxNodes = 250
        let maxDepth = 12

        let tree = crawlNode(
            view: window,
            depth: 0,
            maxDepth: maxDepth,
            nodeCount: &nodeCount,
            maxNodes: maxNodes,
            maskedCount: &maskedCount,
            maskAllText: maskAllText
        )

        return (tree, maskedCount)
    }

    @MainActor
    private func crawlNode(
        view: UIView,
        depth: Int,
        maxDepth: Int,
        nodeCount: inout Int,
        maxNodes: Int,
        maskedCount: inout Int,
        maskAllText: Bool
    ) -> MobileViewNode {
        nodeCount += 1
        let isMasked = MaskingRules.shouldMask(view: view, maskAllText: maskAllText)
        if isMasked {
            maskedCount += 1
        }

        let f = view.frame
        let frameArray = [
            Double(round(f.origin.x)),
            Double(round(f.origin.y)),
            Double(round(f.size.width)),
            Double(round(f.size.height))
        ]
        let clsName = String(describing: type(of: view))

        let text = extractText(from: view, isMasked: isMasked)

        // Cegah double text pada leaf input & tombol UIKit
        let isLeafInputOrButton = (view is UIButton) || (view is UITextField) || (view is UITextView)

        var children: [MobileViewNode] = []
        if depth < maxDepth && nodeCount < maxNodes && !isMasked && !isLeafInputOrButton {
            for sub in view.subviews {
                if nodeCount >= maxNodes { break }
                guard !sub.isHidden && sub.alpha >= 0.01 else { continue }

                // Abaikan subview internal private Apple yang sering memicu double render
                let subCls = String(describing: type(of: sub))
                if subCls == "UIButtonLabel" || subCls.hasPrefix("_UIBarBackground") {
                    continue
                }

                children.append(
                    crawlNode(
                        view: sub,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        nodeCount: &nodeCount,
                        maxNodes: maxNodes,
                        maskedCount: &maskedCount,
                        maskAllText: maskAllText
                    )
                )
            }

            // Ekstraksi elemen untuk SwiftUI (HostingView) atau container tanpa viewleaf
            let isHostingView = clsName.contains("HostingView")
            let accessibilityNodes = extractAccessibilityNodes(
                from: view,
                isMasked: isMasked,
                nodeCount: &nodeCount,
                maxNodes: maxNodes
            )
            if !accessibilityNodes.isEmpty {
                if isHostingView || children.isEmpty {
                    children = accessibilityNodes
                } else {
                    children.append(contentsOf: accessibilityNodes)
                }
            }
        }

        return MobileViewNode(
            cls: clsName,
            frame: frameArray,
            hidden: view.isHidden ? true : nil,
            masked: isMasked ? true : nil,
            text: text,
            children: children.isEmpty ? nil : children
        )
    }

    @MainActor
    private func extractAccessibilityNodes(
        from view: UIView,
        isMasked: Bool,
        nodeCount: inout Int,
        maxNodes: Int
    ) -> [MobileViewNode] {
        var rawElements: [Any] = []
        if let elArray = view.accessibilityElements, !elArray.isEmpty {
            rawElements = elArray
        } else {
            let count = view.accessibilityElementCount()
            if count > 0 && count != NSNotFound {
                for i in 0..<count {
                    if let el = view.accessibilityElement(at: i) {
                        rawElements.append(el)
                    }
                }
            }
        }

        guard !rawElements.isEmpty else { return [] }

        var result: [MobileViewNode] = []
        for raw in rawElements {
            if nodeCount >= maxNodes { break }
            guard let obj = raw as? NSObject else { continue }

            if let isHidden = obj.value(forKey: "accessibilityElementsHidden") as? Bool, isHidden {
                continue
            }

            var elFrame: CGRect = .zero
            if let el = obj as? UIAccessibilityElement {
                elFrame = el.accessibilityFrame
            } else if let rectVal = obj.value(forKey: "accessibilityFrame") as? NSValue {
                elFrame = rectVal.cgRectValue
            } else if let elView = obj as? UIView {
                elFrame = elView.accessibilityFrame
            }

            let convertedX = elFrame.origin.x - view.accessibilityFrame.origin.x
            let convertedY = elFrame.origin.y - view.accessibilityFrame.origin.y

            let label = obj.accessibilityLabel ?? (obj.value(forKey: "accessibilityLabel") as? String)
                ?? obj.accessibilityValue ?? (obj.value(forKey: "accessibilityValue") as? String)

            let traits = obj.accessibilityTraits
            let isButton = traits.contains(.button)
            let isStaticText = traits.contains(.staticText) || traits.contains(.header)
            let cls = isButton ? "UIButton" : (isStaticText || label != nil ? "UILabel" : "UIView")

            let node = MobileViewNode(
                cls: cls,
                frame: [
                    Double(round(convertedX)),
                    Double(round(convertedY)),
                    Double(round(elFrame.size.width)),
                    Double(round(elFrame.size.height))
                ],
                hidden: nil,
                masked: isMasked ? true : nil,
                text: isMasked ? "••••••••" : label,
                children: nil
            )
            result.append(node)
            nodeCount += 1
        }
        return result
    }

    @MainActor
    private func extractText(from view: UIView, isMasked: Bool) -> String? {
        if isMasked {
            return "••••••••"
        }

        // Hindari membaca text pada internal label jika superview-nya adalah UIButton
        if let superview = view.superview, superview is UIButton {
            return nil
        }

        if let label = view as? UILabel {
            return label.text
        }

        if let btn = view as? UIButton {
            return btn.currentTitle ?? btn.accessibilityLabel
        }

        if let tf = view as? UITextField {
            if tf.isSecureTextEntry { return "••••••••" }
            return tf.text ?? tf.placeholder
        }

        if let tv = view as? UITextView {
            return tv.text
        }

        // SwiftUI Text/Button inspection via accessibility
        if let accessLabel = view.accessibilityLabel, !accessLabel.isEmpty {
            let traits = view.accessibilityTraits
            if traits.contains(.button) || traits.contains(.staticText) || view.subviews.isEmpty {
                return accessLabel
            }
        }

        return nil
    }
}
#endif
