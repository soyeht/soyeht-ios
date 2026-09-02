import Darwin
import Foundation
import SoyehtCore

/// The engine URL this Mac hands the iPhone while pairing — the one the
/// phone keeps.
///
/// `ActiveHouseholdState.endpoint` on the phone is a `let`, and refresh
/// copies it verbatim, so whatever this returns during pairing is the
/// address the phone uses for the life of the pairing. Handing out a LAN
/// address to a phone that could have used the tailnet is the most common
/// way a paying user becomes unreachable the moment they leave the house —
/// and it is silent: the phone works at home and times out everywhere else.
///
/// Until 2026-09-01 the tailnet address came from `tailscale status --json`,
/// run from two hard-coded Homebrew paths, in two separate copies of this
/// logic. Tailscale installed the normal way (the .app) has no binary at
/// either path, and on a Mac where the binary exists the CLI can hang past
/// its 2 s budget (measured: LocalAPI stuck for twelve days, datapath fine).
/// Both cases fell through to a `192.168.x` address — while the setup UI
/// showed "Tailscale detected". Now the tailnet address is read from the
/// interfaces, the same place the datapath gets it, with no subprocess.
///
/// Decision and gathering are separate so the rule is testable: the tailnet
/// address wins whenever there is one, a LAN address is only ever a
/// fallback, and the loopback base URL is the last resort.
/// No AppKit: this file is symlinked into the isolated domain test package.
enum MacEngineAdvertisedURL {

    /// Decision only.
    static func resolve(tailnetIPv4: String?, lanIPv4: String?, localEngineBaseURL: URL) -> URL {
        let port = localEngineBaseURL.port ?? EndpointPolicy.defaultBootstrapPort()
        if let tailnetIPv4, HostClassifier.isTailnetIPv4(tailnetIPv4),
           let url = EndpointPolicy.bootstrapStatusBaseURL(forHost: "\(tailnetIPv4):\(port)") {
            return url
        }
        if let lanIPv4, isLANReachableIPv4(lanIPv4),
           let url = EndpointPolicy.bootstrapStatusBaseURL(forHost: "\(lanIPv4):\(port)") {
            return url
        }
        return localEngineBaseURL
    }

    /// Gathers from the live interfaces and decides.
    static func current(localEngineBaseURL: URL) -> URL {
        resolve(
            tailnetIPv4: TailnetAddressResolver.currentTailnetIPv4(),
            lanIPv4: lanIPv4Addresses().first,
            localEngineBaseURL: localEngineBaseURL
        )
    }

    /// Non-loopback, up, LAN-reachable IPv4 addresses, `en0` first. Tailnet
    /// addresses are excluded by construction — they are never a LAN
    /// fallback, they are the primary answer above.
    static func lanIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var values: [(rank: Int, ip: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let ip = String(cString: buffer)
            guard isLANReachableIPv4(ip) else { continue }
            let rank = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            values.append((rank, ip))
        }
        return values.sorted { lhs, rhs in lhs.rank < rhs.rank }.map(\.ip)
    }

    static func isLANReachableIPv4(_ value: String) -> Bool {
        HostClassifier.bonjourIPv4EndpointRank(value) != nil
            && !HostClassifier.isTailnetIPv4(value)
    }
}
