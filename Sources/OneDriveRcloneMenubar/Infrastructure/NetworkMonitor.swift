import Network

/// Reports whether the current network is one that scheduled syncs should avoid:
/// Low Data Mode (constrained) or metered, such as a phone hotspot (expensive).
final class NetworkMonitor: Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor", qos: .utility))
    }

    var isLowDataNetwork: Bool {
        let path = monitor.currentPath
        return path.isConstrained || path.isExpensive
    }
}
