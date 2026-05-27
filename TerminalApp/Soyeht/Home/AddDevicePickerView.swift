import SwiftUI
import SoyehtCore

/// Sheet presented from InstanceList's "+" so users adding a second device
/// see a Linux pairing guide before being thrown into a raw QR scanner.
/// US-F: closes the "I have a Mac, how do I add a Linux?" discovery gap.
struct AddDevicePickerView: View {
    /// Called when the user wants to land in the raw QR/paste-link scanner.
    /// SSHLoginView dismisses the sheet and flips `appState` to `.qrScanner`.
    let onScanPairingLink: () -> Void
    /// Called when the user dismisses the sheet without picking anything.
    let onDismiss: () -> Void

    /// Source of truth for "is there a Soyeht identity?". When
    /// `identity.active` is nil the "Mac" card is hidden — the user must
    /// finish initial setup before adding a second machine. Observed so
    /// the picker reactively reveals the Mac option if the identity is
    /// resolved while the sheet is on screen (e.g. unlock after cold
    /// launch into `.unavailable(.protectedDataUnavailable)`).
    @ObservedObject private var identity: SoyehtIdentity

    init(
        onScanPairingLink: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        identity: SoyehtIdentity? = nil
    ) {
        self.onScanPairingLink = onScanPairingLink
        self.onDismiss = onDismiss
        // Direct `= SoyehtIdentity.shared` as a default-value expression
        // is rejected under Swift 6 strict concurrency (default
        // expressions are non-isolated). Resolve inside the init body
        // where the surrounding view init is on the main actor.
        self.identity = identity ?? SoyehtIdentity.shared
    }

    private enum Screen: Equatable {
        case picker
        case linuxGuide
        /// Transitional: we tapped "Mac" and are minting a setup invitation
        /// (which includes capturing the APNs token). Shows a brief spinner
        /// so the user gets immediate feedback even when APNs is slow.
        case preparingMac
        case awaitingMac(SetupInvitationPayload, SoyehtIdentitySnapshot)
    }

    @State private var screen: Screen = .picker

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            switch screen {
            case .picker:
                pickerContent
            case .linuxGuide:
                LinuxPairingGuideView(
                    onScanPairingLink: onScanPairingLink,
                    onBack: { screen = .picker }
                )
            case .preparingMac:
                preparingMacContent
            case .awaitingMac(let invitation, let snapshot):
                AwaitingNewMacView(
                    invitation: invitation,
                    identity: snapshot,
                    onCompleted: onDismiss,
                    onCancel: { screen = .picker }
                )
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            dismissBar
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heading
                    optionCards
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
    }

    private var dismissBar: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(BrandColors.textMuted)
            }
            .accessibilityLabel(Text(LocalizedStringResource(
                "addDevice.dismiss.a11y",
                defaultValue: "Close",
                comment: "VoiceOver label for the dismiss button on the Add Device picker."
            )))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(
                "addDevice.title",
                defaultValue: "Add a device",
                comment: "Add Device picker title shown when the user taps the + button on the instance list."
            ))
            .font(OnboardingFonts.headingLarge)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(LocalizedStringResource(
                "addDevice.subtitle",
                defaultValue: "Connect a Linux machine, or use an existing pairing link.",
                comment: "Add Device picker subtitle explaining the two ways to add a second machine."
            ))
            .font(OnboardingFonts.callout)
            .foregroundColor(BrandColors.textMuted)
        }
    }

    private var optionCards: some View {
        VStack(spacing: 12) {
            if identity.isActive {
                Button(action: beginAddMac) {
                    AddDeviceOptionCard(
                        icon: "laptopcomputer",
                        title: LocalizedStringResource(
                            "addDevice.option.mac",
                            defaultValue: "Mac",
                            comment: "Add Device option leading to the iPhone-orchestrated add-Mac flow."
                        ),
                        detail: LocalizedStringResource(
                            "addDevice.option.mac.detail",
                            defaultValue: "Mint an invitation here, or scan a QR shown by the Mac.",
                            comment: "Detail line for the Mac option on the Add Device picker."
                        )
                    )
                }
                .buttonStyle(.plain)
            }

            Button(action: { screen = .linuxGuide }) {
                AddDeviceOptionCard(
                    icon: "terminal",
                    title: LocalizedStringResource(
                        "addDevice.option.linux",
                        defaultValue: "Linux machine",
                        comment: "Add Device option leading to the Linux pairing guide."
                    ),
                    detail: LocalizedStringResource(
                        "addDevice.option.linux.detail",
                        defaultValue: "Step-by-step guide to run soyeht pair on Linux.",
                        comment: "Detail line for the Linux machine option on the Add Device picker."
                    )
                )
            }
            .buttonStyle(.plain)

            Button(action: onScanPairingLink) {
                AddDeviceOptionCard(
                    icon: "qrcode.viewfinder",
                    title: LocalizedStringResource(
                        "addDevice.option.scan",
                        defaultValue: "I have a pairing link",
                        comment: "Add Device option for users who already have a QR or theyos:// link."
                    ),
                    detail: LocalizedStringResource(
                        "addDevice.option.scan.detail",
                        defaultValue: "Scan a QR code or paste a theyos:// link.",
                        comment: "Detail line for the scan-or-paste option on the Add Device picker."
                    )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var preparingMacContent: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.4)
                .tint(BrandColors.accentGreen)
            Text(LocalizedStringResource(
                "addDevice.preparingMac",
                defaultValue: "Preparing...",
                comment: "Brief transitional spinner while the iPhone mints a setup invitation before opening the Add Mac flow."
            ))
            .font(OnboardingFonts.subheadline)
            .foregroundColor(BrandColors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func beginAddMac() {
        guard let snapshot = identity.active else { return }
        let device = identity.thisDevice
        screen = .preparingMac
        Task { @MainActor in
            let invitation = await AddDevicePickerInvitationBuilder.makeSetupInvitation(device: device)
            // The screen could have been dismissed between tap and the
            // async result — only transition if we're still preparing.
            if case .preparingMac = screen {
                screen = .awaitingMac(invitation, snapshot)
            }
        }
    }
}

// MARK: - Invitation builder

/// Mirrors the static `makeSetupInvitationPayload()` AppDelegate uses
/// during initial onboarding (Caso B). Lifted here so the Add Device
/// picker doesn't depend on AppDelegate internals.
@MainActor
private enum AddDevicePickerInvitationBuilder {
    static func makeSetupInvitation(device: OwnerDevice) async -> SetupInvitationPayload {
        let apnsToken = await captureAPNsToken()
        return SetupInvitationPayload(
            token: SetupInvitationToken(),
            ownerDisplayName: nil,
            expiresAt: UInt64(Date().timeIntervalSince1970) + 3600,
            iphoneApnsToken: apnsToken,
            iphoneDeviceID: device.localPairingDeviceId,
            iphoneDeviceName: device.displayName,
            iphoneDeviceModel: device.model
        )
    }

    /// Tries the registrar's cached token first (fast path), then falls
    /// back to a 3s-bounded fresh request. On simulator or if APNs is
    /// unavailable, returns nil — invitation publication still works,
    /// the Mac just can't push back via APNs.
    private static func captureAPNsToken() async -> Data? {
        if let cached = APNsTokenRegistrar.shared.persistedToken() {
            return cached
        }
        #if targetEnvironment(simulator)
        return nil
        #else
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await APNsTokenRegistrar.shared.requestAndCapture() }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CancellationError()
                }
                guard let token = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return token
            }
        } catch {
            return APNsTokenRegistrar.shared.persistedToken()
        }
        #endif
    }
}

private struct AddDeviceOptionCard: View {
    let icon: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(BrandColors.accentGreen)
                .frame(width: 32, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Font.body.weight(.medium))
                    .foregroundColor(BrandColors.textPrimary)
                Text(detail)
                    .font(OnboardingFonts.caption)
                    .foregroundColor(BrandColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.forward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(BrandColors.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(BrandColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(BrandColors.border, lineWidth: 1)
        )
    }
}
