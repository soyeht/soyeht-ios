import SwiftUI

/// The primary action of a screen: accent fill, white label, a coloured glow.
public struct NeoPillButtonStyle: ButtonStyle {
    public enum Prominence: Equatable, Sendable { case primary, secondary }

    private let palette: NeoPalette
    private let prominence: Prominence
    private let fillsWidth: Bool

    public init(_ prominence: Prominence = .primary, palette: NeoPalette, fillsWidth: Bool = true) {
        self.palette = palette
        self.prominence = prominence
        self.fillsWidth = fillsWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(NeoFont.cta)
            .foregroundStyle(prominence == .primary ? palette.onAccent : palette.text)
            .padding(.horizontal, 24)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 52)
            .modifier(NeoPillBackground(palette: palette, prominence: prominence, pressed: pressed))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

private struct NeoPillBackground: ViewModifier {
    let palette: NeoPalette
    let prominence: NeoPillButtonStyle.Prominence
    let pressed: Bool

    func body(content: Content) -> some View {
        switch prominence {
        case .primary:
            content
                .background(palette.accent, in: Capsule())
                .compositingGroup()
                .opacity(pressed ? 0.9 : 1)
                .neoAccentGlow(palette, elevation: pressed ? .chip : .pill)
        case .secondary:
            if pressed {
                content.neoPressed(palette, radius: NeoRadius.pill, elevation: .chip)
            } else {
                content.neoRaised(palette, radius: NeoRadius.pill, elevation: .pill)
            }
        }
    }
}

/// A text-only action: no surface, so it never competes with the pill above it.
public struct NeoLinkButtonStyle: ButtonStyle {
    private let palette: NeoPalette

    public init(palette: NeoPalette) { self.palette = palette }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NeoFont.caption)
            .foregroundStyle(palette.muted)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A raised card. Padding is the caller's; the card only provides the surface.
public struct NeoCard<Content: View>: View {
    private let palette: NeoPalette
    private let elevation: NeoElevation
    private let content: Content

    public init(
        palette: NeoPalette,
        elevation: NeoElevation = .card,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.elevation = elevation
        self.content = content()
    }

    public var body: some View {
        content.neoRaised(palette, radius: NeoRadius.card, elevation: elevation)
    }
}

/// One word of a pairing code, sunk into the canvas so the six of them read as
/// a row of slots rather than six buttons.
public struct NeoWordWell: View {
    private let index: Int
    private let word: String
    private let palette: NeoPalette

    public init(index: Int, word: String, palette: NeoPalette) {
        self.index = index
        self.word = word
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(NeoFont.monoSmall)
                .foregroundStyle(palette.muted)
            Text(word)
                .font(NeoFont.mono)
                .foregroundStyle(palette.text)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .neoWell(palette)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(index): \(word)"))
    }
}

/// A switch shaped like the rest of the style: the track is a well, the knob a
/// raised face that takes the accent when it is on.
public struct NeoToggleStyle: ToggleStyle {
    private let palette: NeoPalette

    public init(palette: NeoPalette) { self.palette = palette }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .font(NeoFont.body)
                .foregroundStyle(palette.text)
            Spacer(minLength: 12)
            track(isOn: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(configuration.isOn ? "on" : "off"))
    }

    private func track(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? palette.accent : palette.well)
                .frame(width: 52, height: 30)
                .overlay {
                    if !isOn {
                        Capsule().strokeBorder(palette.wellShadow.opacity(0.5), lineWidth: 1)
                    }
                }
            Circle()
                .fill(palette.face)
                .frame(width: 24, height: 24)
                .shadow(color: palette.shadowDark, radius: NeoElevation.chip.renderRadius, x: 1, y: 1)
                .padding(.horizontal, 3)
        }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// A field the owner types into: a well, never a bordered box.
public struct NeoTextFieldStyle: TextFieldStyle {
    private let palette: NeoPalette

    public init(palette: NeoPalette) { self.palette = palette }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(NeoFont.body)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .neoWell(palette)
    }
}
