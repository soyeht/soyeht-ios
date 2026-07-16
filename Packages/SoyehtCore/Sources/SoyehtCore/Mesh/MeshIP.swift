import CryptoKit
import Foundation

/// Byte-exact Swift port of the mesh tunnel-IP derivation used by the peer.
///
/// Both peers derive their local `/32` and the remote allowed-IP with this
/// function. A one-byte disagreement would produce different routes, so the
/// vectors in `MeshIPTests` intentionally pin the formula.
public enum MeshIP {
    /// `sha256(normalize(networkId) + "\n" + pubkeyHex)` →
    /// `10.44.(d0 % 254 + 1).(d1 % 254 + 1)/32`.
    ///
    /// `pubkeyHex` is the 64-character x-only public-key hex string. Returns
    /// `nil` when either input is empty after normalization.
    public static func deriveTunnelIP(networkId: String, pubkeyHex: String) -> String? {
        let normalizedNetworkID = normalizeRuntimeNetworkID(networkId)
        let normalizedPublicKey = pubkeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNetworkID.isEmpty, !normalizedPublicKey.isEmpty else { return nil }

        var hasher = SHA256()
        hasher.update(data: Data(normalizedNetworkID.utf8))
        hasher.update(data: Data("\n".utf8))
        hasher.update(data: Data(normalizedPublicKey.utf8))
        let digest = Array(hasher.finalize())

        let thirdOctet = Int(digest[0]) % 254 + 1
        let fourthOctet = Int(digest[1]) % 254 + 1
        return "10.44.\(thirdOctet).\(fourthOctet)/32"
    }

    /// Normalizes a runtime network ID: trim; remove whitespace and `-`; if
    /// what remains is hexadecimal, lowercase it. Non-hex IDs retain their
    /// trimmed spelling because it is part of the peer-compatible hash input.
    static func normalizeRuntimeNetworkID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = String(trimmed.filter { !$0.isWhitespace && $0 != "-" })
        if !compact.isEmpty, compact.allSatisfy(\.isHexDigit) {
            return compact.lowercased()
        }
        return trimmed
    }
}
