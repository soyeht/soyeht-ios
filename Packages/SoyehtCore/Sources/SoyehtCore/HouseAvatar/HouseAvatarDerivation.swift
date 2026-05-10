import CryptoKit
import Foundation

/// Deterministic avatar derivation from a 33-byte SEC1-compressed P-256 public key.
///
/// Algorithm (data-model.md Avatar section + research R4):
/// ```
/// hash      = SHA-256(hh_pub)           // 32 bytes
/// emoji_idx = u32_be(hash[0..4]) % 512
/// color_h   = u16_be(hash[4..6]) % 360  → 0..359°
/// color_s   = 60 + (hash[6] % 26)       → 60..85%
/// color_l   = 50 + (hash[7] % 21)       → 50..70%
/// ```
///
/// **Invariant**: same `hh_pub` bytes ALWAYS produce the same `HouseAvatar`.
/// Do not change the algorithm or catalog indices after shipping (FR-046).
public enum HouseAvatarDerivation {
    /// Derives a `HouseAvatar` deterministically from a household public key.
    /// - Parameter hhPub: 33-byte SEC1 compressed P-256 EC public key.
    public static func derive(hhPub: Data) -> HouseAvatar {
        let hash = SHA256.hash(data: hhPub)
        let bytes = Array(hash)

        let emojiIdx = u32be(bytes, offset: 0) % UInt32(HouseAvatarEmojiCatalog.count)
        let colorH   = UInt16(u16be(bytes, offset: 4) % 360)
        let colorS   = UInt8(60 + (bytes[6] % 26))
        let colorL   = UInt8(50 + (bytes[7] % 21))

        return HouseAvatar(
            emoji: HouseAvatarEmojiCatalog.emoji(at: Int(emojiIdx)),
            colorH: colorH,
            colorS: colorS,
            colorL: colorL
        )
    }

    // MARK: - Byte helpers

    private static func u32be(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset    ]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) <<  8
        | UInt32(bytes[offset + 3])
    }

    private static func u16be(_ bytes: [UInt8], offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}
