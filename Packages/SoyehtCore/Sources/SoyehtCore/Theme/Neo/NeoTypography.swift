import SwiftUI

/// The type scale of the neo chrome. Nunito for everything the owner reads,
/// JetBrains Mono only where the content is code-like — a pairing word, a
/// path. The terminal itself never uses these.
public enum NeoFont {
    #if os(macOS)
    private static let titleSize: CGFloat = 28
    private static let bodySize: CGFloat = 15
    #else
    private static let titleSize: CGFloat = 30
    private static let bodySize: CGFloat = 16
    #endif

    public static var title: Font {
        Typography.neoSans(size: titleSize, weight: .bold, relativeTo: .largeTitle)
    }

    public static var heading: Font {
        Typography.neoSans(size: 20, weight: .semibold, relativeTo: .title3)
    }

    public static var body: Font {
        Typography.neoSans(size: bodySize, weight: .regular, relativeTo: .body)
    }

    public static var cta: Font {
        Typography.neoSans(size: 16, weight: .semibold, relativeTo: .body)
    }

    public static var caption: Font {
        Typography.neoSans(size: 13, weight: .regular, relativeTo: .footnote)
    }

    /// A pairing word, a port, a path: mono so a human can read it aloud or
    /// copy it without doubt about which character is which.
    public static var mono: Font {
        Typography.mono(size: 15, weight: .semibold)
    }

    public static var monoSmall: Font {
        Typography.mono(size: 13, weight: .medium)
    }
}
