import Foundation
import Network
import NetworkExtension

struct RelayStreamIPv4Assignment: Sendable, Equatable {
    let address: String
    let prefixLength: UInt8
    let peer: String
}

enum RelayStreamIPTunnelNetworkSettingsError: Error, Sendable, Equatable {
    case invalidAddress
    case invalidPeer
    case invalidPrefix
    case unusableHost
    case peerOutsidePool
    case invalidMTU
    case invalidSessionID
}

enum RelayStreamIPTunnelNetworkSettings {
    static func make(
        assignment: RelayStreamIPv4Assignment,
        mtu: UInt16,
        sessionID: String
    ) throws -> NEPacketTunnelNetworkSettings {
        guard let address = parseIPv4(assignment.address) else {
            throw RelayStreamIPTunnelNetworkSettingsError.invalidAddress
        }
        guard let peer = parseIPv4(assignment.peer) else {
            throw RelayStreamIPTunnelNetworkSettingsError.invalidPeer
        }
        guard (1...31).contains(Int(assignment.prefixLength)) else {
            throw RelayStreamIPTunnelNetworkSettingsError.invalidPrefix
        }
        guard (1_280...9_000).contains(Int(mtu)) else {
            throw RelayStreamIPTunnelNetworkSettingsError.invalidMTU
        }
        guard !sessionID.isEmpty else {
            throw RelayStreamIPTunnelNetworkSettingsError.invalidSessionID
        }

        let mask = UInt32.max << (32 - UInt32(assignment.prefixLength))
        let network = address & mask
        let broadcast = network | ~mask
        let reservesNetworkAndBroadcast = assignment.prefixLength <= 30
        guard address != peer,
              isUsableUnicast(address),
              isUsableUnicast(peer),
              !reservesNetworkAndBroadcast || (
                  address != network
                      && address != broadcast
                      && peer != network
                      && peer != broadcast
              )
        else {
            throw RelayStreamIPTunnelNetworkSettingsError.unusableHost
        }
        guard peer & mask == network else {
            throw RelayStreamIPTunnelNetworkSettingsError.peerOutsidePool
        }

        let addressString = ipv4String(address)
        let peerString = ipv4String(peer)
        let maskString = ipv4String(mask)
        let networkString = ipv4String(network)
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: peerString
        )
        let ipv4 = NEIPv4Settings(
            addresses: [addressString],
            subnetMasks: [maskString]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(
                destinationAddress: networkString,
                subnetMask: maskString
            ),
        ]
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: mtu)
        return settings
    }

    private static func parseIPv4(_ value: String) -> UInt32? {
        guard let address = IPv4Address(value),
              address.rawValue.count == 4
        else {
            return nil
        }
        return address.rawValue.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func isUsableUnicast(_ address: UInt32) -> Bool {
        let firstOctet = address >> 24
        let firstTwoOctets = address >> 16
        return address != 0
            && address != UInt32.max
            && firstOctet != 0
            && firstOctet != 127
            && firstTwoOctets != 0xA9FE
            && firstOctet < 224
    }

    private static func ipv4String(_ value: UInt32) -> String {
        [
            value >> 24,
            value >> 16 & 0xFF,
            value >> 8 & 0xFF,
            value & 0xFF,
        ]
        .map(String.init)
        .joined(separator: ".")
    }
}
