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
    let onContinueOnMac: @MainActor () async -> LocalizedStringResource?
    let onPaired: () -> Void

    private static let qrContext = CIContext()

    @State private var isPulsing = false
    @State private var showInfoSheet = false
    @State private var pairingError: LocalizedStringResource?
    @State private var continueError: LocalizedStringResource?
    @State private var isContinuingOnMac = false
    @State private var pairingComplete = false
    @State private var copiedPairLink = false
    @State private var showFallbackPairing = false
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
                        defaultValue: "Add your iPhone now, or continue on this Mac.",
                        comment: "House card subtitle confirming creation."
                    ))
                    .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                    .foregroundColor(BrandColors.textMuted)
                }

                deviceList

                actionButtons

                statusMessage
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if !reduceMotion { isPulsing = true } }
        .onDisappear {
            pairingComplete = true
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .task { await pollUntilPaired() }
        .task { await listenForIPhoneInvitations() }
        .sheet(isPresented: $showInfoSheet) {
            IPhonePairingSheetContent(
                title: LocalizedStringResource(
                    "bootstrap.houseCard.iphone.info.title",
                    defaultValue: "Open on iPhone",
                    comment: "Info sheet title after tapping iPhone slot on house card."
                ),
                instructions: [
                    LocalizedStringResource(
                        "bootstrap.houseCard.iphone.info.body",
                        defaultValue: "Open Soyeht on your iPhone and start looking for this Mac.",
                        comment: "Info sheet body for iPhone slot tap."
                    ),
                    LocalizedStringResource(
                        "bootstrap.houseCard.iphone.network.body",
                        defaultValue: "Keep both devices on the same LAN or Wi-Fi, or connected through Tailscale. Guest networks can block pairing.",
                        comment: "Network requirement for Mac and iPhone pairing."
                    ),
                ],
                homeCodeWords: Self.securityCodeWords(from: pairQrUri),
                status: IPhonePairingSheetStatus(
                    message: LocalizedStringResource(
                        "bootstrap.houseCard.iphone.waiting",
                        defaultValue: "Waiting for iPhone...",
                        comment: "Status shown while the Mac is listening for an iPhone setup invitation."
                    ),
                    showsProgress: true
                ),
                pairingURI: pairQrUri,
                showFallbackPairing: $showFallbackPairing,
                copiedPairLink: copiedPairLink,
                onCopyPairLink: copyPairLink
            )
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "bootstrap.houseCard.a11y",
            defaultValue: "\(houseName) created. Add an iPhone or continue on this Mac.",
            comment: "House card VoiceOver summary with house name."
        )))
    }

    @ViewBuilder private var statusMessage: some View {
        if let pairingError {
            Text(pairingError)
                .font(MacTypography.Fonts.welcomeProgressBody)
                .foregroundColor(BrandColors.accentAmber)
                .multilineTextAlignment(.center)
        } else if let continueError {
            Text(continueError)
                .font(MacTypography.Fonts.welcomeProgressBody)
                .foregroundColor(BrandColors.accentAmber)
                .multilineTextAlignment(.center)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: openIPhoneSheet) {
                Text(LocalizedStringResource(
                    "bootstrap.houseCard.primary.addIPhone",
                    defaultValue: "Add iPhone",
                    comment: "Primary CTA on the house card. Opens the iPhone pairing sheet."
                ))
                .font(MacTypography.Fonts.Controls.cta)
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(BrandColors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Button(action: continueOnMac) {
                HStack(spacing: 8) {
                    if isContinuingOnMac {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(LocalizedStringResource(
                        "bootstrap.houseCard.secondary.continueOnMac",
                        defaultValue: "Continue on Mac",
                        comment: "Secondary CTA on the house card. Lets the user use the Mac app without adding an iPhone now."
                    ))
                    .font(MacTypography.Fonts.Controls.cta)
                }
                .foregroundColor(BrandColors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(BrandColors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isContinuingOnMac)
        }
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

    private var fallbackPairingSection: some View {
        VStack(spacing: 14) {
            Text(LocalizedStringResource(
                "bootstrap.houseCard.iphone.fallback",
                defaultValue: "Fallback pairing code",
                comment: "Header for QR/link fallback when direct discovery is unavailable."
            ))
            .font(MacTypography.Fonts.welcomeProgressTitle)
            .foregroundColor(BrandColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let qrImage = Self.makeQRImage(from: pairQrUri) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(BrandColors.qrCodeBackground)
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
        }
    }

    private func securityCodeSection(_ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "bootstrap.houseCard.iphone.security.title",
                defaultValue: "Security code",
                comment: "Header above the security words shown while adding the first iPhone."
            ))
            .font(MacTypography.Fonts.welcomeProgressTitle)
            .foregroundColor(BrandColors.textMuted)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(index + 1)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(BrandColors.textMuted)
                            .frame(width: 16, alignment: .trailing)

                        Text(verbatim: word)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(BrandColors.textPrimary)
                    }
                }
            }

            Text(LocalizedStringResource(
                "bootstrap.houseCard.iphone.security.body",
                defaultValue: "Compare these words with your iPhone before connecting.",
                comment: "Short instruction for validating the Mac/iPhone security code."
            ))
            .font(MacTypography.Fonts.welcomeProgressBody)
            .foregroundColor(BrandColors.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(BrandColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        Button(action: openIPhoneSheet) {
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

    private func openIPhoneSheet() {
        showFallbackPairing = false
        showInfoSheet = true
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

    private func continueOnMac() {
        guard !isContinuingOnMac else { return }
        isContinuingOnMac = true
        continueError = nil
        Task { @MainActor in
            let error = await onContinueOnMac()
            isContinuingOnMac = false
            continueError = error
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

    private static func securityCodeWords(from deepLink: String) -> [String]? {
        guard let url = URL(string: deepLink),
              let qr = try? PairDeviceQR(url: url, now: Date()),
              let fingerprint = try? OperatorFingerprint.derive(
                machinePublicKey: qr.householdPublicKey,
                pairingNonce: qr.nonce,
                wordlist: try BIP39Wordlist()
              ),
              fingerprint.words.count == OperatorFingerprint.wordCount else {
            return nil
        }
        return fingerprint.words
    }

    private func pollUntilPaired() async {
        let client = BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL)

        while !Task.isCancelled {
            if let status = try? await client.fetch() {
                switch status.state {
                case .ready:
                    await MainActor.run {
                        pairingComplete = true
                        showInfoSheet = false
                        onPaired()
                    }
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

    private func listenForIPhoneInvitations() async {
        let hostLabel = Host.current().localizedName ?? "Mac"
        let existingHouse = SetupInvitationExistingHouse(
            name: houseName,
            hostLabel: hostLabel,
            pairDeviceURI: pairQrUri
        )

        while !Task.isCancelled {
            if await MainActor.run(body: { pairingComplete }) {
                return
            }

            let listener = SetupInvitationListener(
                engineBaseURL: TheyOSEnvironment.bootstrapBaseURL,
                existingHouse: existingHouse
            )
            let outcome = await listener.listen()
            guard !Task.isCancelled else { return }

            switch outcome {
            case .invitationClaimed:
                return
            case .notFound:
                try? await Task.sleep(for: .milliseconds(500))
            case .failed:
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct IPhonePairingSheetStatus {
    let message: LocalizedStringResource
    let showsProgress: Bool
}

struct IPhonePairingSheetContent: View {
    let title: LocalizedStringResource
    let instructions: [LocalizedStringResource]
    let homeCodeWords: [String]?
    let status: IPhonePairingSheetStatus?
    let pairingURI: String
    @Binding var showFallbackPairing: Bool
    let copiedPairLink: Bool
    let onCopyPairLink: () -> Void
    var closeAction: (() -> Void)?

    private static let qrContext = CIContext()

    init(
        title: LocalizedStringResource,
        instructions: [LocalizedStringResource],
        homeCodeWords: [String]?,
        status: IPhonePairingSheetStatus?,
        pairingURI: String,
        showFallbackPairing: Binding<Bool>,
        copiedPairLink: Bool,
        onCopyPairLink: @escaping () -> Void,
        closeAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.instructions = instructions
        self.homeCodeWords = homeCodeWords
        self.status = status
        self.pairingURI = pairingURI
        self._showFallbackPairing = showFallbackPairing
        self.copiedPairLink = copiedPairLink
        self.onCopyPairLink = onCopyPairLink
        self.closeAction = closeAction
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(title)
                    .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
                    .foregroundColor(BrandColors.textPrimary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                        Text(instruction)
                            .font(index == 0 ? MacTypography.Fonts.Onboarding.flowBody(compact: false) : MacTypography.Fonts.welcomeProgressBody)
                            .foregroundColor(index == 0 ? BrandColors.textPrimary : BrandColors.textMuted)
                            .multilineTextAlignment(.center)
                    }
                }

                if let words = homeCodeWords {
                    homeSecurityCodeSection(words)
                }

                if let status {
                    HStack(spacing: 10) {
                        if status.showsProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(status.message)
                            .font(MacTypography.Fonts.welcomeProgressBody)
                            .foregroundColor(BrandColors.textMuted)
                    }
                    .padding(.vertical, 4)
                }

                if showFallbackPairing {
                    fallbackPairingSection
                } else if !pairingURI.isEmpty {
                    Button(action: { showFallbackPairing = true }) {
                        Text(LocalizedStringResource(
                            "bootstrap.houseCard.iphone.fallback.button",
                            defaultValue: "Use QR/link instead",
                            comment: "Button that reveals the manual QR and link fallback."
                        ))
                    }
                    .buttonStyle(.bordered)
                }

                if let closeAction {
                    Button(action: closeAction) {
                        Text(LocalizedStringResource(
                            "common.button.close",
                            defaultValue: "Close",
                            comment: "Generic close button label."
                        ))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(32)
        }
        .frame(width: 440)
        .frame(maxHeight: 620)
    }

    private func homeSecurityCodeSection(_ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "iphonePairing.homeSecurityCode.title",
                defaultValue: "Home security code",
                comment: "Header above stable home fingerprint words shown while adding an iPhone."
            ))
            .font(MacTypography.Fonts.welcomeProgressTitle)
            .foregroundColor(BrandColors.textMuted)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(index + 1)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(BrandColors.textMuted)
                            .frame(width: 16, alignment: .trailing)

                        Text(verbatim: word)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(BrandColors.textPrimary)
                    }
                }
            }

            Text(LocalizedStringResource(
                "iphonePairing.homeSecurityCode.body",
                defaultValue: "Match these words with your iPhone to confirm it found this home.",
                comment: "Short instruction for validating the stable home security code."
            ))
            .font(MacTypography.Fonts.welcomeProgressBody)
            .foregroundColor(BrandColors.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(BrandColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fallbackPairingSection: some View {
        VStack(spacing: 14) {
            Text(LocalizedStringResource(
                "bootstrap.houseCard.iphone.fallback",
                defaultValue: "Fallback pairing code",
                comment: "Header for QR/link fallback when direct discovery is unavailable."
            ))
            .font(MacTypography.Fonts.welcomeProgressTitle)
            .foregroundColor(BrandColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let qrImage = Self.makeQRImage(from: pairingURI) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(BrandColors.qrCodeBackground)
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
        }
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

            Text(verbatim: pairingURI)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(BrandColors.textPrimary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(BrandColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: onCopyPairLink) {
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
