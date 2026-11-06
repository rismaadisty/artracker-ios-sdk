import Foundation

public struct Breadcrumb: Codable, Sendable, Equatable {
    public let type: String
    public let category: String
    public let message: String
    public let timestamp: String

    public init(
        type: String = "default",
        category: String = "ui",
        message: String,
        timestamp: String = DefaultClock.shared.nowISO8601()
    ) {
        self.type = String(type.prefix(64))
        self.category = String(category.prefix(64))
        self.message = String(message.prefix(1024))
        self.timestamp = timestamp
    }
}

public final class BreadcrumbStore: @unchecked Sendable {
    public static let shared = BreadcrumbStore()

    private let lock = UnfairLock()
    private var buffer: [Breadcrumb] = []
    private var capacity: Int = 50

    public init(capacity: Int = 50) {
        self.capacity = max(10, capacity)
    }

    public func setCapacity(_ newCapacity: Int) {
        lock.withLock {
            self.capacity = max(10, newCapacity)
            if buffer.count > self.capacity {
                buffer = Array(buffer.suffix(self.capacity))
            }
        }
    }

    public func add(_ breadcrumb: Breadcrumb) {
        lock.withLock {
            if buffer.count >= capacity {
                buffer.removeFirst()
            }
            buffer.append(breadcrumb)
            CrashContextStore.shared.recordBreadcrumb(breadcrumb)
        }
    }

    public func all() -> [Breadcrumb] {
        lock.withLock {
            Array(buffer)
        }
    }

    public func asJSONValue() -> JSONValue {
        lock.withLock {
            let crumbs: [JSONValue] = buffer.map { c in
                .object([
                    "type": .string(c.type),
                    "category": .string(c.category),
                    "message": .string(c.message),
                    "timestamp": .string(c.timestamp)
                ])
            }
            return .array(crumbs)
        }
    }

    public func clear() {
        lock.withLock {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

