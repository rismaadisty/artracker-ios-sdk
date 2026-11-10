import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Lightweight primitive struct captured on Main Thread (< 1.5ms).
/// Sendable & Equatable for deduplication on background queue.
public struct RawWireframeNode: Sendable, Equatable {
    public let id: Int
    public let parentId: Int?
    public let frame: [Double] // [x, y, width, height] in window points
    public let tag: String // "div", "button", "span", "input"
    public let text: String?
    public let isMasked: Bool
    public let backgroundColor: String? // Hex or rgba string, e.g. "#FFFFFF" or "rgba(0,0,0,0.5)"
    public let textColor: String?
    public let fontSize: Double?
    public let fontWeight: String? // "bold", "600", "normal"
    public let borderRadius: Double?
    public let borderWidth: Double?
    public let borderColor: String?
    public let isImagePlaceholder: Bool
    public let customClassName: String?

    public init(
        id: Int,
        parentId: Int? = nil,
        frame: [Double],
        tag: String = "div",
        text: String? = nil,
        isMasked: Bool = false,
        backgroundColor: String? = nil,
        textColor: String? = nil,
        fontSize: Double? = nil,
        fontWeight: String? = nil,
        borderRadius: Double? = nil,
        borderWidth: Double? = nil,
        borderColor: String? = nil,
        isImagePlaceholder: Bool = false,
        customClassName: String? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.frame = frame
        self.tag = tag
        self.text = text
        self.isMasked = isMasked
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.borderRadius = borderRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.isImagePlaceholder = isImagePlaceholder
        self.customClassName = customClassName
    }
}

