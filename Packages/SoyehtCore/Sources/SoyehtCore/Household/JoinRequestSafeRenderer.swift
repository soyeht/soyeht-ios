import Foundation

public enum JoinRequestSafeRenderer: Sendable {
    public static let defaultMaxCharacters = 64
    public static let replacementScalar: Unicode.Scalar = "\u{FFFD}"
    public static let truncationSuffix: Character = "…"

    private static let bidiOverrideScalars: Set<Unicode.Scalar> = [
        "\u{202A}",  // LEFT-TO-RIGHT EMBEDDING
        "\u{202B}",  // RIGHT-TO-LEFT EMBEDDING
        "\u{202C}",  // POP DIRECTIONAL FORMATTING
        "\u{202D}",  // LEFT-TO-RIGHT OVERRIDE
        "\u{202E}",  // RIGHT-TO-LEFT OVERRIDE
        "\u{2066}",  // LEFT-TO-RIGHT ISOLATE
        "\u{2067}",  // RIGHT-TO-LEFT ISOLATE
        "\u{2068}",  // FIRST STRONG ISOLATE
        "\u{2069}",  // POP DIRECTIONAL ISOLATE
    ]

    public static func render(
        _ raw: String,
        maxCharacters: Int = JoinRequestSafeRenderer.defaultMaxCharacters
    ) -> String {
        var sanitised = String.UnicodeScalarView()
        sanitised.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if bidiOverrideScalars.contains(scalar) { continue }
            if isControlScalar(scalar) {
                sanitised.append(replacementScalar)
            } else {
                sanitised.append(scalar)
            }
        }
        let cleaned = String(sanitised)
        guard maxCharacters > 0 else { return "" }
        if cleaned.count <= maxCharacters { return cleaned }

        let suffixLength = 1
        let prefixLength = max(0, maxCharacters - suffixLength)
        let prefix = cleaned.prefix(prefixLength)
        var truncated = String(prefix)
        truncated.append(truncationSuffix)
        return truncated
    }

    private static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value <= 0x1F { return true }            // C0
        if value == 0x7F { return true }            // DEL
        if value >= 0x80 && value <= 0x9F { return true }  // C1
        return false
    }
}
