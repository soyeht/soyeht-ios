import Foundation
import Security

/// 32-byte crypto-random token that authenticates a SetupInvitation claim.
/// Single-use; entropy = 256 bits (brute force in 3600s TTL window is infeasible).
public struct SetupInvitationToken: Equatable, Sendable {
    /// Always exactly 32 bytes.
    public let bytes: Data

    /// Generates a new cryptographically-random token via `SecRandomCopyBytes`.
    public init() {
        var raw = Data(count: 32)
        let status = raw.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        bytes = raw
    }

    /// Wraps raw bytes received over the wire. Must be exactly 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw SetupInvitationTokenError.wrongLength(actual: bytes.count)
        }
        self.bytes = bytes
    }
}

public enum SetupInvitationTokenError: Error, Equatable, Sendable {
    case wrongLength(actual: Int)
}
