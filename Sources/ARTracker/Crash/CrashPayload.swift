import Foundation

public struct BinaryImageInfo: Codable, Sendable, Equatable {
    public let uuid: String
    public let name: String
    public let loadAddress: String

    enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case loadAddress = "load_address"
    }

    public init(uuid: String, name: String, loadAddress: String) {
        self.uuid = uuid
        self.name = name
        self.loadAddress = loadAddress
    }
}

public struct CrashPayload: Sendable {
    public let errorType: String
    public let message: String
    public let stackTrace: String
    public let timestamp: String
    public let thread: String
    public let isFatal: Bool
    public let binaryImages: [BinaryImageInfo]
    public let rawReportData: Data?

    public init(
        errorType: String,
        message: String,
        stackTrace: String,
        timestamp: String,
        thread: String = "com.apple.main-thread",
        isFatal: Bool = true,
        binaryImages: [BinaryImageInfo] = [],
        rawReportData: Data? = nil
    ) {
        self.errorType = errorType
        self.message = message
        self.stackTrace = stackTrace
        self.timestamp = timestamp
        self.thread = thread
        self.isFatal = isFatal
        self.binaryImages = binaryImages
        self.rawReportData = rawReportData
    }
}

