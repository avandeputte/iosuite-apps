import Foundation
import Network

extension Notification.Name {
    /// The device reaches the internet another way now (home Wi-Fi to cellular, another Wi-Fi).
    static let iopixNetworkMoved = Notification.Name("iopixNetworkMoved")
}

/// Watches which way the device is connected. Away from home the server's name leads to Cloudflare instead of the
/// house, so the screens load again by the new route (and find out whether Cloudflare wants a sign-in first).
final class NetworkRoute {
    static let shared = NetworkRoute()

    private let monitor = NWPathMonitor()
    private var last: (kinds: Set<NWInterface.InterfaceType>, gateways: Set<String>)?
    private var settle: DispatchWorkItem?
    private let queue = DispatchQueue(label: "iopix.route")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.changed(path) }
        monitor.start(queue: queue)
    }

    private func changed(_ path: NWPath) {
        // the route matters (Wi-Fi or cellular in use, which gateway), not every interface that comes and goes
        let kinds = Set([NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other].filter { path.usesInterfaceType($0) })
        let now = (kinds: kinds, gateways: Set(path.gateways.map { "\($0)" }))
        defer { last = now }
        guard path.status == .satisfied, let last, last.kinds != now.kinds || last.gateways != now.gateways else { return }
        settle?.cancel()
        let work = DispatchWorkItem {
            IopixClient.shared.networkMoved()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .iopixNetworkMoved, object: nil) }
        }
        settle = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)  // let the new network settle
    }
}
