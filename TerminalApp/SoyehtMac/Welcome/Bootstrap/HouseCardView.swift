import SwiftUI
import SoyehtCore
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// MA4 — House card scene shown after house creation.
/// Displays avatar + name + Mac as host + pulsing "add iPhone" slot per FR-017.
struct HouseCardView: View {
    let houseName: String
    let avatar: HouseAvatar
    let pairQrUri: String
    let onPaired: () -> Void

    private static let qrContext = CIContext()

    @State private var isPulsing = false
    @State private var showInfoSheet = false
    @State private var pairingError: LocalizedStringResource?
    @State private var copiedPairLink = false
    @State private var copyResetTask: Task<Void, Never>?
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
                        defaultValue: "Your home is alive.",
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
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .task { await pollUntilPaired() }
        .sheet(isPresented: $showInfoSheet) {
            ScrollView {
                VStack(spacing: 18) {
                    Text(LocalizedStringResource(
                        "bootstrap.houseCard.iphone.info.title",
                        defaultValue: "Scan on iPhone",
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
                                defaultValue: "QR code to add this iPhone to the home.",
                                comment: "VoiceOver label for the first iPhone pairing QR."
                            )))
                    } else {
                        Text(LocalizedStringResource(
                            "bootstrap.houseCard.iphone.qr.error",
                            defaultValue: "Couldn't generate the QR code. Close this screen and try again.",
                            comment: "Fallback shown if first iPhone QR rendering fails."
                        ))
                        .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                        .foregroundColor(BrandColors.accentAmber)
                        .multilineTextAlignment(.center)
                    }

                    pairLinkSection

                    Text(LocalizedStringResource(
                        "bootstrap.houseCard.iphone.info.body",
                        defaultValue: "Open Soyeht on an iPhone connected to the same network as this Mac and point the camera at this code, or use the link above.",
                        comment: "Info sheet body for iPhone slot tap."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                    .multilineTextAlignment(.center)
                }
                .padding(32)
            }
            .frame(width: 440)
            .frame(maxHeight: 620)
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCard.a11y",
            defaultValue: "\(houseName) created. Add an iPhone to continue.",
            comment: "House card VoiceOver summary with house name."
        )))
    }

    private var pairLinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringResource(
                "bootstrap.houseCard.iphone.link.header",
                defaultValue: "LINK",
                comment: "Header above the copyable first-iPhone pairing link."
            ))
            .font(MacTypography.Fonts.welcomeProgressTitle)
            .foregroundColor(BrandColors.textMuted)

            Text(verbatim: pairQrUri)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(BrandColors.textPrimary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(BrandColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: copyPairLink) {
                Text(copiedPairLink ? LocalizedStringResource(
                    "bootstrap.houseCard.iphone.link.copied",
                    defaultValue: "Link copied",
                    comment: "Temporary state after copying first-iPhone pairing link."
                ) : LocalizedStringResource(
                    "bootstrap.houseCard.iphone.link.copy",
                    defaultValue: "Copy link",
                    comment: "Button that copies the first-iPhone pairing link."
                ))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceList: some View {
        VStack(spacing: 12) {
            DeviceRow(
                icon: "desktopcomputer",
                name: Host.current().localizedName ?? "Mac",
                badge: LocalizedStringResource(
                    "bootstrap.houseCard.mac.badge",
                    defaultValue: "computer",
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
                    defaultValue: "add iPhone",
                    comment: "Pulsing iPhone slot on house card — prompts adding first resident."
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
            defaultValue: "Add iPhone as the first member",
            comment: "VoiceOver label for the iPhone slot button."
        )))
    }

    private func copyPairLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairQrUri, forType: .string)
        copiedPairLink = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedPairLink = false
        }
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
        let client = BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL)

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
                            defaultValue: "Pairing was interrupted. Close and reopen Soyeht to try again.",
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
                .foregroundColor(BrandColors.readableTextOnSelection)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(BrandColors.selection)
                .clipShape(Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}
