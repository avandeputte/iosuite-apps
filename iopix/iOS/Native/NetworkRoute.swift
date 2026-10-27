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
    private var last: NetworkIdentity?
    private var settle: DispatchWorkItem?
    private let queue = DispatchQueue(label: "iopix.route")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.changed(path) }
        monitor.start(queue: queue)
    }

    private func changed(_ path: NWPath) {
        // another router or cellular, not Ethernet to Wi-Fi in the same house (NetworkIdentity)
        guard path.status == .satisfied else { return }
        let now = NetworkIdentity(path)
        guard let last else { last = now; return }
        if now.gateways.isEmpty && !now.cellular { return }  // still coming up: wait for its router
        self.last = now
        guard now.isMove(from: last) else { return }
        settle?.cancel()
        let work = DispatchWorkItem {
            IopixClient.shared.networkMoved()  // fresh connections, and a few seconds' grace before a sign-in is believed
            DispatchQueue.main.async { NotificationCenter.default.post(name: .iopixNetworkMoved, object: nil) }
        }
        settle = work
        queue.asyncAfter(deadline: .now() + 2.5, execute: work)  // let the new network settle
    }
}
