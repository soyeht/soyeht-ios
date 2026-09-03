import SwiftUI

/// A determinate bar: the track is a well, the fill takes the accent and its
/// glow, so progress reads as something rising out of the surface.
public struct NeoProgressBar: View {
    private let progress: Double
    private let label: String?
    private let palette: NeoPalette

    public init(progress: Double, label: String? = nil, palette: NeoPalette) {
        self.progress = min(max(progress, 0), 1)
        self.label = label
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.well)
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: max(geo.size.width * progress, progress > 0 ? 12 : 0))
                        .neoAccentGlow(palette, elevation: .chip)
                }
            }
            .frame(height: 12)
            if let label {
                Text(label)
                    .font(NeoFont.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(verbatim: "\(Int(progress * 100))%"))
        .accessibilityLabel(Text(label ?? ""))
    }
}

/// The step indicator. Done and current steps are raised; the ones ahead are
/// wells, so the row reads as a path with a position on it.
public struct NeoProgressDots: View {
    private let count: Int
    private let current: Int
    private let palette: NeoPalette
    private let accessibilityText: String

    public init(count: Int, current: Int, palette: NeoPalette, accessibilityText: String) {
        self.count = count
        self.current = current
        self.palette = palette
        self.accessibilityText = accessibilityText
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                dot(at: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder
    private func dot(at index: Int) -> some View {
        if index == current {
            Capsule()
                .fill(palette.accent)
                .frame(width: 26, height: 10)
                .neoAccentGlow(palette, elevation: .chip)
        } else if index < current {
            Circle()
                .fill(palette.accent.opacity(0.45))
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(palette.well)
                .frame(width: 10, height: 10)
        }
    }
}

/// The looking-for-your-Mac radar: three rings breathing outward from a raised
/// centre. Honours Reduce Motion by standing still.
public struct NeoRadar: View {
    private let palette: NeoPalette
    private let isSearching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    public init(palette: NeoPalette, isSearching: Bool = true) {
        self.palette = palette
        self.isSearching = isSearching
    }

    public var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(palette.accent.opacity(0.18), lineWidth: 2)
                    .scaleEffect(scale(for: ring))
                    .opacity(opacity(for: ring))
            }
            Circle()
                .fill(palette.face)
                .frame(width: 84, height: 84)
                .shadow(color: palette.shadowDark, radius: NeoElevation.card.renderRadius, x: 4, y: 4)
                .shadow(color: palette.shadowLight, radius: NeoElevation.card.renderRadius, x: -4, y: -4)
        }
        .frame(width: 200, height: 200)
        .onAppear {
            guard isSearching, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
        .accessibilityHidden(true)
    }

    private func scale(for ring: Int) -> CGFloat {
        guard animating else { return 0.5 + CGFloat(ring) * 0.2 }
        return 1.0
    }

    private func opacity(for ring: Int) -> Double {
        guard animating else { return 1 }
        return 0
    }
}

/// The live/offline dot next to a machine's name.
public struct NeoStatusDot: View {
    private let isLive: Bool
    private let palette: NeoPalette

    public init(isLive: Bool, palette: NeoPalette) {
        self.isLive = isLive
        self.palette = palette
    }

    public var body: some View {
        Circle()
            .fill(isLive ? palette.success : palette.muted)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
