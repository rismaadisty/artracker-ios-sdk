import Foundation

public struct SDKInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String

    public static let current = SDKInfo(name: "artracker-ios", version: "0.1.0")
}

public struct Envelope: Codable, Sendable, Equatable {
    public let sentAt: String
    public let sdk: SDKInfo
    public let context: DeviceContext
    public let items: [Item]

    enum CodingKeys: String, CodingKey {
        case sentAt = "sent_at"
        case sdk
        case context
        case items
    }

    public init(
        sentAt: String = DefaultClock.shared.nowISO8601(),
        sdk: SDKInfo = .current,
        context: DeviceContext,
        items: [Item]
    ) {
        self.sentAt = sentAt
        self.sdk = sdk
        self.context = context
        self.items = items
    }
}

