import Darwin
import Foundation
import os

/// Resolves the iPhone's current Tailnet IPv4 address by walking the local
/// network interfaces.
///
/// Background: when the iPhone publishes the `_soyeht-setup._tcp.` Bonjour
/// service while connected to both Wi-Fi and Tailscale, mDNSResponder
/// advertises on every interface — even though `NWParameters` restricts the
/// listener socket to `.other` (utun). The theyos engine's
/// `bonjour_trust::should_emit` filter then suppresses the announcement as
/// `non_tailnet`. To recover trust, the publisher embeds the iPhone's Tailnet
/// IPv4 in the TXT record as `tailnet_addr`, and the engine validates that
/// value before accepting the service.
///
/// This helper inspects `getifaddrs(3)` for IPv4 addresses on `utun*`
/// interfaces inside the Tailscale CGNAT range `100.64.0.0/10`. It returns
/// `nil` when Tailscale is not running or no Tailnet IP can be located.
///
/// The type is a `enum` namespace and the function is pure (no global state),
/// so it is safe to call from any actor.
public enum TailnetAddressResolver {
    private static let logger = Logger(
        subsystem: "com.soyeht.core",
        category: "tailnet-resolver"
    )

    /// Returns the device's current Tailnet IPv4 address (a string in the
    /// `100.64.0.0/10` CGNAT range advertised on any `utun*` interface), or
    /// `nil` if no such address is configured.
    public static func currentTailnetIPv4() -> String? {
        let address = enumerateTailnetIPv4()
        logger.debug("currentTailnetIPv4 resolved: \(address ?? "nil", privacy: .public)")
        return address
    }

    /// Capability observation for address selection, including IPv6-only
    /// tailnet interfaces. Failure to read interfaces is unknown, not absent.
    public static func currentHasTailnetAddress() -> Bool? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        var unreadableAddress = false
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  (Int32(item.pointee.ifa_flags) & IFF_UP) != 0,
                  (Int32(item.pointee.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                unreadableAddress = true
                continue
            }
            if HostClassifier.isTailnetHost(String(cString: buffer)) { return true }
        }
        return unreadableAddress ? nil : false
    }

    /// Pure predicate: is `address` an IPv4 string in Tailscale's CGNAT
    /// range `100.64.0.0/10`?
    ///
    /// Exposed for unit tests; production callers should use
    /// `currentTailnetIPv4()` instead.
    public static func isTailnetIPv4(_ address: String) -> Bool {
        HostClassifier.isTailnetIPv4(address)
    }

    // MARK: - Private

    private static func enumerateTailnetIPv4() -> String? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
            return nil
        }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sockaddrPtr = entry.pointee.ifa_addr else { continue }
            guard sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }

            var address = sockaddr_in()
            memcpy(&address, sockaddrPtr, MemoryLayout<sockaddr_in>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let result = withUnsafePointer(to: &address.sin_addr) { addrPtr in
                inet_ntop(AF_INET, addrPtr, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
            guard result != nil else { continue }
            let ipString = String(cString: buffer)
            if isTailnetIPv4(ipString) {
                return ipString
            }
        }
        return nil
    }
}
