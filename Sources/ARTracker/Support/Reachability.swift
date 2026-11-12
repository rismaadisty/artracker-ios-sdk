import Foundation
import Network

public final class Reachability: @unchecked Sendable {
    public static let shared = Reachability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "id.art.tracker.reachability", qos: .utility)
    private let lock = UnfairLock()
    private var _isConnected: Bool = true
    private var _isExpensive: Bool = false
    private var _isConstrained: Bool = false
    private var _interfaceKind: String? = nil
    private var _isStarted: Bool = false

    public init() {}

    public func start() {
        lock.withLock {
            guard !_isStarted else { return }
            _isStarted = true
            monitor.pathUpdateHandler = { [weak self] path in
                let kind = NetKind.from(
                    satisfied: path.status == .satisfied,
                    wifi: path.usesInterfaceType(.wifi),
                    cellular: path.usesInterfaceType(.cellular),
                    wired: path.usesInterfaceType(.wiredEthernet)
                )
                self?.lock.withLock {
                    self?._isConnected = (path.status == .satisfied)
                    self?._isExpensive = path.isExpensive
                    self?._isConstrained = path.isConstrained
                    self?._interfaceKind = kind
                }
            }
            monitor.start(queue: queue)
        }
    }

    public func stop() {
        lock.withLock {
            guard _isStarted else { return }
            monitor.cancel()
            _isStarted = false
        }
    }

    public var isConnected: Bool {
        lock.withLock { _isConnected }
    }

    public var isExpensive: Bool {
        lock.withLock { _isExpensive }
    }

    public var isWiFi: Bool {
        lock.withLock { _isConnected && !_isExpensive }
    }

    internal var interfaceKind: String? {
        lock.withLock { _interfaceKind }
    }

    public func canUpload(wifiOnly: Bool) -> Bool {
        lock.withLock {
            guard _isConnected else { return false }
            if wifiOnly {
                return !_isExpensive
            }
            return true
        }
    }
}

