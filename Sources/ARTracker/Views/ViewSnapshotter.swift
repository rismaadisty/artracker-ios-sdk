import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct ViewTreeNode: Codable, Sendable, Equatable {
    public let cls: String
    public let id: String?
    public let frame: [Double]
    public let hidden: Bool
    public let masked: Bool
    public let children: [ViewTreeNode]
}

public final class ViewSnapshotter: @unchecked Sendable {
    public static let shared = ViewSnapshotter()

    private let lock = UnfairLock()
    private var lastSnapshotTime: TimeInterval = 0
    private var lastCapturedScreen: String?
    private let throttleInterval: TimeInterval = 2.0 // 1x per 2 seconds

    public func shouldCapture(screen: String? = nil) -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            // Always capture when transitioning to a different screen
            if let screen = screen, screen != lastCapturedScreen {
                lastCapturedScreen = screen
                lastSnapshotTime = now
                return true
            }
            if now - lastSnapshotTime >= throttleInterval {
                lastSnapshotTime = now
                return true
            }
            return false
        }
    }

    #if canImport(UIKit)
    @MainActor
    public func capture(view: UIView, maskAllText: Bool) -> (tree: ViewTreeNode, maskedCount: Int) {
        var nodeCount = 0
        var maskedTotal = 0
        let root = buildNode(view: view, depth: 0, maxDepth: 12, nodeCount: &nodeCount, maxNodes: 300, maskedTotal: &maskedTotal, maskAllText: maskAllText)
        return (root, maskedTotal)
    }

    @MainActor
    private func buildNode(
        view: UIView,
        depth: Int,
        maxDepth: Int,
        nodeCount: inout Int,
        maxNodes: Int,
        maskedTotal: inout Int,
        maskAllText: Bool
    ) -> ViewTreeNode {
        nodeCount += 1
        let isMasked = MaskingRules.shouldMask(view: view, maskAllText: maskAllText)
        if isMasked {
            maskedTotal += 1
        }

        let f = view.frame
        let frameArray = [Double(f.origin.x), Double(f.origin.y), Double(f.size.width), Double(f.size.height)]
        let clsName = String(describing: type(of: view))

        var children: [ViewTreeNode] = []
        if depth < maxDepth && nodeCount < maxNodes && !isMasked {
            for sub in view.subviews {
                if nodeCount >= maxNodes { break }
                children.append(
                    buildNode(
                        view: sub,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        nodeCount: &nodeCount,
                        maxNodes: maxNodes,
                        maskedTotal: &maskedTotal,
                        maskAllText: maskAllText
                    )
                )
            }
        }

        return ViewTreeNode(
            cls: clsName,
            id: view.accessibilityIdentifier,
            frame: frameArray,
            hidden: view.isHidden,
            masked: isMasked,
            children: children
        )
    }
    #endif
}

