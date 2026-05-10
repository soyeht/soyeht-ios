import Foundation

/// Deterministic visual identity for a house, derived from `hh_pub` (FR-046).
///
/// Derivation (data-model.md Avatar section):
/// ```
/// hash       = SHA-256(hh_pub)
/// emoji_idx  = u32_be(hash[0..4]) mod 512
/// color_h    = u16_be(hash[4..6]) mod 360   → 0..359
/// color_s    = 60 + (hash[6] mod 26)         → 60..85
/// color_l    = 50 + (hash[7] mod 21)         → 50..70
/// ```
///
/// **Persistence rule**: compute once at house creation, store the result.
/// Never recompute on the render path (FR-046).
public struct HouseAvatar: Equatable, Sendable {
    /// Single emoji chosen from the 512-entry curated catalog (Unicode 12, stable).
    public let emoji: Character
    /// HSL hue in degrees (0–359).
    public let colorH: UInt16
    /// HSL saturation percent (60–85).
    public let colorS: UInt8
    /// HSL lightness percent (50–70).
    public let colorL: UInt8

    public init(emoji: Character, colorH: UInt16, colorS: UInt8, colorL: UInt8) {
        self.emoji = emoji
        self.colorH = colorH
        self.colorS = colorS
        self.colorL = colorL
    }
}
