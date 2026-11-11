import Foundation

/// Frame payload structure matching official `artracker-screen-v1` screenshot replay contract.
public struct ScreenFramePayload: Codable, Sendable {
    public let ts: Int64
    public let screen: String
    public let w: Int
    public let h: Int
    public let vw: Double
    public let vh: Double
    public let mime: String
    public let data: String
    public let masked: Bool?

    public init(
        ts: Int64,
        screen: String,
        w: Int,
        h: Int,
        vw: Double,
        vh: Double,
        mime: String = "image/jpeg",
        data: String,
        masked: Bool? = nil
    ) {
        self.ts = ts
        self.screen = screen
        self.w = w
        self.h = h
        self.vw = vw
        self.vh = vh
        self.mime = mime
        self.data = data
        self.masked = masked
    }
}

/// Touch / tap / gesture event matching official `artracker-screen-v1` touch point.
/// Supported kinds: "down", "move", "up".
public struct ScreenTouchPoint: Codable, Sendable, Equatable {
    public let ts: Int64
    public let x: Double
    public let y: Double
    public let kind: String

    public init(ts: Int64, x: Double, y: Double, kind: String = "up") {
        self.ts = ts
        self.x = x
        self.y = y
        self.kind = kind
    }
}

/// Root chunk envelope conforming to `artracker-screen-v1`.
public struct ScreenChunkPayload: Codable, Sendable {
    public let format: String
    public let platform: String
    public let seq: Int
    public let frames: [ScreenFramePayload]
    public let touches: [ScreenTouchPoint]

    public init(
        format: String = "artracker-screen-v1",
        platform: String = "ios",
        seq: Int,
        frames: [ScreenFramePayload],
        touches: [ScreenTouchPoint]
    ) {
        self.format = format
        self.platform = platform
        self.seq = seq
        self.frames = frames
        self.touches = touches
    }
}

