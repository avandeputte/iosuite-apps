import Foundation
import Network

/// Which network the device is on, as far as reaching iopix goes. Wired and Wi-Fi in the same house share the
/// router, so they count as the same network: only the router's address (its IPv4 gateway, or a global IPv6 one)
/// and cellular tell networks apart. The interface type and link-local IPv6 gateways (fe80::, different on every
/// interface) are left out, so moving from Ethernet to Wi-Fi at home is not mistaken for leaving home.
struct NetworkIdentity: Equatable {
    let gateways: Set<String>
    let cellular: Bool

    init(_ path: NWPath) {
        cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
        gateways = Set(path.gateways.compactMap { e -> String? in
            guard case let .hostPort(host, _) = e else { return nil }
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a):
                let s = "\(a)".lowercased()
                return s.hasPrefix("fe80") ? nil : s.split(separator: "%").first.map(String.init)
            default: return nil
            }
        })
    }

    /// A different place to reach iopix from: a different router, or cellular in place of a router. A network
    /// with no gateway known yet (still coming up) is not counted as a move.
    func isMove(from old: NetworkIdentity) -> Bool {
        if cellular != old.cellular { return true }
        guard !gateways.isEmpty, !old.gateways.isEmpty else { return false }
        return gateways.isDisjoint(with: old.gateways)
    }
}
