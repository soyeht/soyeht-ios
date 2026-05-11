import SwiftUI
import SoyehtCore
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// MA4 — House card scene shown after house creation.
/// Displays avatar + name + Mac as host + pulsing "adicionar iPhone" slot per FR-017.
struct HouseCardView: View {
    let houseName: String
    let avatar: HouseAvatar
    let pairQrUri: String
    let onPaired: () -> Void

    private static let qrContext = CIContext()

    @State private var isPulsing = false
    @State private var showInfoSheet = false
    @State private var pairingError: LocalizedStringResource?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                HouseAvatarView(avatar: avatar, animateReveal: true)

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

                if let pairingError {
                    Text(pairingError)
                        .font(MacTypography.Fonts.welcomeProgressBody)
                        .foregroundColor(BrandColors.accentAmber)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if !reduceMotion { isPulsing = true } }
        .task { await pollUntilPaired() }
        .sheet(isPresented: $showInfoSheet) {
            VStack(spacing: 18) {
                Text(LocalizedStringResource(
                    "bootstrap.houseCard.iphone.info.title",
                    defaultValue: "Escaneie no iPhone",
                    comment: "Info sheet title after tapping iPhone slot on house card."
                ))
                .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                .foregroundColor(BrandColors.textPrimary)

                if let qrImage = Self.makeQRImage(from: pairQrUri) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "bootstrap.houseCard.iphone.qr.a11y",
                            defaultValue: "Código QR para adicionar este iPhone à casa.",
                            comment: "VoiceOver label for the first iPhone pairing QR."
                        )))
                } else {
                    Text(LocalizedStringResource(
                        "bootstrap.houseCard.iphone.qr.error",
                        defaultValue: "Não consegui gerar o QR. Feche esta tela e tente de novo.",
                        comment: "Fallback shown if first iPhone QR rendering fails."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.accentAmber)
                    .multilineTextAlignment(.center)
                }

                Text(LocalizedStringResource(
                    "bootstrap.houseCard.iphone.info.body",
                    defaultValue: "Abra o Soyeht no iPhone conectado à mesma rede que este Mac e aponte a câmera para este código.",
                    comment: "Info sheet body for iPhone slot tap."
                ))
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(minWidth: 360)
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCard.a11y",
            defaultValue: "Casa \(houseName) criada. Adicione um iPhone para continuar.",
            comment: "House card VoiceOver summary with house name."
        )))
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
        Button(action: { showInfoSheet = true }) {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCard.iphone.slot.a11y",
            defaultValue: "Adicionar iPhone como primeiro morador",
            comment: "VoiceOver label for the iPhone slot button."
        )))
    }

    private static func makeQRImage(from deepLink: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(deepLink.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = qrContext.createCGImage(output, from: output.extent) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: output.extent.width, height: output.extent.height)
        )
    }

    private func pollUntilPaired() async {
        let scheme = SoyehtAPIClient.isLocalHost(TheyOSEnvironment.adminHost) ? "http" : "https"
        guard let baseURL = URL(string: "\(scheme)://\(TheyOSEnvironment.adminHost)") else { return }
        let client = BootstrapStatusClient(baseURL: baseURL)

        while !Task.isCancelled {
            if let status = try? await client.fetch() {
                switch status.state {
                case .ready:
                    await MainActor.run { onPaired() }
                    return
                case .namedAwaitingPair, .recovering:
                    break
                case .uninitialized, .readyForNaming:
                    await MainActor.run {
                        pairingError = LocalizedStringResource(
                            "bootstrap.houseCard.pairing.regressed",
                            defaultValue: "O pareamento foi interrompido. Feche e abra o Soyeht para tentar de novo.",
                            comment: "Shown if the engine regresses while the Mac waits for the first iPhone pair."
                        )
                    }
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
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
