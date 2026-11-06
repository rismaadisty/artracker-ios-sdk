import Foundation

public struct PreparedBatch: Sendable {
    public let recordIds: [Int64]
    public let bodyData: Data
    public let isGzip: Bool
    public let itemCount: Int
}

public struct BatchBuilder: Sendable {
    public static func build(
        records: [QueueRecord],
        config: ARTrackerConfig,
        enableGzip: Bool = true
    ) -> PreparedBatch? {
        guard !records.isEmpty else { return nil }

        let items = records.map { $0.item }
        let ids = records.map { $0.id }
        let context = DeviceContext.capture(config: config)
        let envelope = Envelope(context: context, items: items)

        guard let rawJSON = try? JSONEncoder().encode(envelope) else {
            return nil
        }

        if enableGzip, let compressed = try? Gzip.compress(data: rawJSON), compressed.count < rawJSON.count {
            return PreparedBatch(
                recordIds: ids,
                bodyData: compressed,
                isGzip: true,
                itemCount: items.count
            )
        } else {
            return PreparedBatch(
                recordIds: ids,
                bodyData: rawJSON,
                isGzip: false,
                itemCount: items.count
            )
        }
    }
}

