import Foundation

/// Mobile frame structure matching official `artracker-mobile-v1` spec.
public struct MobileFramePayload: Codable, Sendable {
    public let ts: Int64
    public let screen: String
    public let presentation: String?
    public let maskedCount: Int?
    public let viewTree: MobileViewNode

    enum CodingKeys: String, CodingKey {
        case ts
        case screen
        case presentation
        case maskedCount = "masked_count"
        case viewTree = "view_tree"
    }

    public init(
        ts: Int64,
        screen: String,
        presentation: String? = "push",
        maskedCount: Int? = 0,
        viewTree: MobileViewNode
    ) {
        self.ts = ts
        self.screen = screen
        self.presentation = presentation
        self.maskedCount = maskedCount
        self.viewTree = viewTree
    }
}

/// Recursive native view node conforming to the frontend `ViewNode` interface.
public struct MobileViewNode: Codable, Sendable, Equatable {
    public let cls: String
    public let frame: [Double] // [x, y, width, height]
    public let hidden: Bool?
    public let masked: Bool?
    public let text: String?
    public let children: [MobileViewNode]?

    public init(
        cls: String,
        frame: [Double],
        hidden: Bool? = nil,
        masked: Bool? = nil,
        text: String? = nil,
        children: [MobileViewNode]? = nil
    ) {
        self.cls = cls
        self.frame = frame
        self.hidden = hidden
        self.masked = masked
        self.text = text
        self.children = children
    }
}

/// Touch / tap event matching official `artracker-mobile-v1` touch point.
public struct MobileTouchPoint: Codable, Sendable {
    public let ts: Int64
    public let x: Double
    public let y: Double
    public let name: String?

    public init(ts: Int64, x: Double, y: Double, name: String? = "touch.tap") {
        self.ts = ts
        self.x = x
        self.y = y
        self.name = name
    }
}

/// Root chunk envelope conforming to `artracker-mobile-v1`.
public struct MobileChunkPayload: Codable, Sendable {
    public let format: String
    public let platform: String
    public let frames: [MobileFramePayload]
    public let touches: [MobileTouchPoint]

    public init(
        format: String = "artracker-mobile-v1",
        platform: String = "ios",
        frames: [MobileFramePayload],
        touches: [MobileTouchPoint]
    ) {
        self.format = format
        self.platform = platform
        self.frames = frames
        self.touches = touches
    }
}

