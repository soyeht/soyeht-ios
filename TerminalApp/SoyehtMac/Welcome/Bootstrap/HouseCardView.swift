import SwiftUI
import SoyehtCore
import AppKit

/// MA4 — House card scene shown after house creation.
/// Displays avatar + name + Mac as host + pulsing "adicionar iPhone" slot per FR-017.
/// Avatar placeholder shown when `avatar` is nil; T049a wires real HouseAvatar from
/// bootstrap/initialize response.
struct HouseCardView: View {
    let houseName: String
    let avatar: HouseAvatar?
    let onPaired: () -> Void

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                avatarCircle

                VStack(spacing: 8) {
                    Text(verbatim: houseName)
                        .font(MacTypography.Fonts.Display.heroTitle)
                        .foregroundColor(BrandColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(LocalizedStringResource(
                        "bootstrap.houseCard.subtitle",
                        defaultValue: "Sua casa está viva.",
                        comment: "House card subtitle confirming creation."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                }

                deviceList
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if !reduceMotion { isPulsing = true } }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCard.a11y",
            defaultValue: "Casa \(houseName) criada. Adicione um iPhone para continuar.",
            comment: "House card VoiceOver summary with house name."
        )))
    }

    private var avatarCircle: some View {
        let emoji = avatar.map { String($0.emoji) } ?? "🏠"
        let bg: Color = avatar.map { av in
            Color(hue: Double(av.colorH) / 360.0, saturation: 0.35, brightness: 0.90)
        } ?? BrandColors.selection
        return Text(emoji)
            .font(.system(size: 48))
            .frame(width: 88, height: 88)
            .background(bg)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private var deviceList: some View {
        VStack(spacing: 12) {
            DeviceRow(
                icon: "desktopcomputer",
                name: Host.current().localizedName ?? "Mac",
                badge: LocalizedStringResource(
                    "bootstrap.houseCard.mac.badge",
                    defaultValue: "computador",
                    comment: "Badge label for Mac host listed on house card."
                )
            )

            iPhoneSlot
        }
        .padding(20)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var iPhoneSlot: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 20))
                .frame(width: 20)
                .foregroundColor(BrandColors.accentGreen)
                .opacity(isPulsing ? 1.0 : 0.35)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)

            Text(LocalizedStringResource(
                "bootstrap.houseCard.iphone.slot",
                defaultValue: "✨ adicionar iPhone",
                comment: "Pulsing iPhone slot on house card — prompts adding first morador."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.accentGreen)
            .opacity(isPulsing ? 1.0 : 0.35)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)

            Spacer()
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCard.iphone.slot.a11y",
            defaultValue: "Slot disponível para adicionar iPhone como primeiro morador",
            comment: "VoiceOver label for the empty iPhone slot."
        )))
    }
}

private struct DeviceRow: View {
    let icon: String
    let name: String
    let badge: LocalizedStringResource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 20)
                .foregroundColor(BrandColors.textPrimary)

            Text(verbatim: name)
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textPrimary)

            Spacer()

            Text(badge)
                .font(MacTypography.Fonts.welcomeProgressTitle)
                .foregroundColor(BrandColors.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(BrandColors.selection)
                .clipShape(Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}
