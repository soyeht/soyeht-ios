import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import SoyehtCore

struct JoinExistingSoyehtView: View {
    let onPaired: () -> Void
    let onBack: () -> Void

    private let stageClient: DaemonPairMachineStageClient
    private let statusClient: BootstrapStatusClient
    private static let qrContext = CIContext()

    @State private var stage: PairMachineStageResult?
    @State private var now = Date()
    @State private var isPreparing = false
    @State private var errorMessage: LocalizedStringResource?
    @State private var isPaired = false
    @State private var copiedLink = false
    @State private var stageTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var tickTask: Task<Void, Never>?
    @State private var copyResetTask: Task<Void, Never>?

    init(
        onPaired: @escaping () -> Void,
        onBack: @escaping () -> Void,
        stageClient: DaemonPairMachineStageClient = DaemonPairMachineStageClient(),
        statusClient: BootstrapStatusClient = BootstrapStatusClient(baseURL: TheyOSEnvironment.bootstrapBaseURL)
    ) {
        self.onPaired = onPaired
        self.onBack = onBack
        self.stageClient = stageClient
        self.statusClient = statusClient
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 26)

            content

            Spacer(minLength: 20)

            footer
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            startTicker()
            if stage == nil, !isPreparing, errorMessage == nil {
                generateNewQR()
            }
        }
        .onDisappear {
            cancelWork()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "welcome.joinExisting.badge",
                defaultValue: "Join existing Soyeht",
                comment: "Badge on Mac join-existing-Soyeht QR screen."
            ))
            .font(MacTypography.Fonts.welcomeProgressTitle)
            .foregroundColor(BrandColors.buttonTextOnAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(BrandColors.accentGreen)
            .clipShape(Capsule())

            Text(LocalizedStringResource(
                "welcome.joinExisting.title",
                defaultValue: "Show this QR on a paired iPhone.",
                comment: "Title on Mac screen that displays a pair-machine QR for an existing Soyeht."
            ))
            .font(MacTypography.Fonts.Onboarding.flowTitle(compact: false))
            .foregroundColor(BrandColors.textPrimary)

            Text(LocalizedStringResource(
                "welcome.joinExisting.subtitle",
                defaultValue: "Open Soyeht on your iPhone, tap Add Server, then scan this code.",
                comment: "Instructions for using the pair-machine QR shown on the Mac."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        if isPaired {
            pairedState
        } else if let errorMessage {
            failedState(errorMessage)
        } else if let stage, secondsRemaining(for: stage) <= 0 {
            expiredState(stage)
        } else if let stage {
            qrState(stage)
        } else {
            preparingState
        }
    }

    private var preparingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
                .tint(BrandColors.accentGreen)
            Text(LocalizedStringResource(
                "welcome.joinExisting.preparing",
                defaultValue: "Preparing QR...",
                comment: "Progress text while the Mac asks the local daemon to stage a pair-machine QR."
            ))
            .font(MacTypography.Fonts.welcomeProgressBody)
            .foregroundColor(BrandColors.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func qrState(_ stage: PairMachineStageResult) -> some View {
        VStack(spacing: 16) {
            if let image = Self.makeQRImage(from: stage.pairMachineURI.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(12)
                    .background(BrandColors.qrCodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "welcome.joinExisting.qr.a11y",
                        defaultValue: "QR code to add this Mac to an existing Soyeht.",
                        comment: "VoiceOver label for the pair-machine QR shown on the Mac."
                    )))
            } else {
                Text(LocalizedStringResource(
                    "welcome.joinExisting.qr.renderFailed",
                    defaultValue: "Couldn't render the QR code. Generate a new one and try again.",
                    comment: "Fallback shown if the pair-machine QR image cannot be rendered."
                ))
                .font(MacTypography.Fonts.welcomeProgressBody)
                .foregroundColor(BrandColors.accentAmber)
            }

            VStack(spacing: 6) {
                Text(verbatim: "transport: \(transportLabel(stage.transportUsed)) · expires in \(Self.formatRemaining(secondsRemaining(for: stage)))")
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.textMuted)

                if stage.fellBackFromTailscale {
                    Text(LocalizedStringResource(
                        "welcome.joinExisting.transport.fallback",
                        defaultValue: "Tailscale is not available on this Mac yet — using LAN.",
                        comment: "Informational line shown when the Mac falls back from Tailscale QR transport to LAN."
                    ))
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.accentAmber)
                    .multilineTextAlignment(.center)
                }

                Text(verbatim: "code \(stage.fingerprint)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(BrandColors.textMuted)
            }

            Button(action: { copy(stage.pairMachineURI.absoluteString) }) {
                Text(copiedLink ? LocalizedStringResource(
                    "welcome.joinExisting.copy.copied",
                    defaultValue: "Link copied",
                    comment: "Temporary button state after copying the join-existing-Soyeht QR link."
                ) : LocalizedStringResource(
                    "welcome.joinExisting.copy",
                    defaultValue: "Copy link",
                    comment: "Button that copies the join-existing-Soyeht QR link."
                ))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func expiredState(_ stage: PairMachineStageResult) -> some View {
        VStack(spacing: 16) {
            qrState(stage)
                .opacity(0.35)

            Text(LocalizedStringResource(
                "welcome.joinExisting.expired",
                defaultValue: "This QR expired.",
                comment: "Shown when the join-existing-Soyeht QR TTL reaches zero."
            ))
            .font(MacTypography.Fonts.welcomeProgressBody)
            .foregroundColor(BrandColors.accentAmber)

            Button(action: generateNewQR) {
                Text(LocalizedStringResource(
                    "welcome.joinExisting.generateNew",
                    defaultValue: "Generate new QR",
                    comment: "Button that stages a fresh join-existing-Soyeht QR after expiration."
                ))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparing)
        }
        .frame(maxWidth: .infinity)
    }

    private func failedState(_ message: LocalizedStringResource) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(BrandColors.accentAmber)
                .accessibilityHidden(true)

            Text(message)
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: generateNewQR) {
                Text(LocalizedStringResource(
                    "welcome.joinExisting.retry",
                    defaultValue: "Try again",
                    comment: "Retry button after staging a join-existing-Soyeht QR fails."
                ))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparing)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var pairedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundColor(BrandColors.accentGreen)
                .accessibilityHidden(true)
            Text(LocalizedStringResource(
                "welcome.joinExisting.paired",
                defaultValue: "This Mac joined your Soyeht.",
                comment: "Success state after the iPhone approves this Mac's pair-machine QR."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var footer: some View {
        HStack {
            Button(action: onBack) {
                Text(LocalizedStringResource(
                    "common.button.back",
                    defaultValue: "Back",
                    comment: "Generic back button label."
                ))
            }
            .buttonStyle(.bordered)
            .disabled(isPreparing)

            Spacer()

            if stage != nil, !isPaired, errorMessage == nil {
                Button(action: generateNewQR) {
                    Text(LocalizedStringResource(
                        "welcome.joinExisting.generateNew",
                        defaultValue: "Generate new QR",
                        comment: "Button that stages a fresh join-existing-Soyeht QR."
                    ))
                }
                .buttonStyle(.bordered)
                .disabled(isPreparing)
            }
        }
    }

    private func generateNewQR() {
        stageTask?.cancel()
        pollTask?.cancel()
        isPreparing = true
        errorMessage = nil
        isPaired = false
        stageTask = Task { @MainActor in
            do {
                let result = try await stageClient.stage()
                guard !Task.isCancelled else { return }
                stage = result
                now = Date()
                isPreparing = false
                startPolling()
            } catch {
                guard !Task.isCancelled else { return }
                stage = nil
                isPreparing = false
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let status = try? await statusClient.fetch(), status.state == .ready {
                    isPaired = true
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    onPaired()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                if let stage, secondsRemaining(for: stage) <= 0 {
                    return
                }
            }
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                now = Date()
                if let stage, secondsRemaining(for: stage) <= 0 {
                    pollTask?.cancel()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func cancelWork() {
        stageTask?.cancel()
        stageTask = nil
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
        copyResetTask?.cancel()
        copyResetTask = nil
    }

    private func secondsRemaining(for stage: PairMachineStageResult) -> Int {
        max(0, Int(Date(timeIntervalSince1970: TimeInterval(stage.ttlUnix)).timeIntervalSince(now)))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedLink = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedLink = false
        }
    }

    private func transportLabel(_ transport: PairMachineStageTransport) -> String {
        switch transport {
        case .tailscale: return "tailscale"
        case .lan: return "lan"
        }
    }

    private static func message(for error: Error) -> LocalizedStringResource {
        switch error {
        case DaemonPairMachineStageError.endpointUnavailable:
            return LocalizedStringResource(
                "welcome.joinExisting.error.endpointUnavailable",
                defaultValue: "This Mac needs the latest Soyeht engine before it can join by QR.",
                comment: "Error shown when /bootstrap/pair-machine/local/stage is not available."
            )
        case DaemonPairMachineStageError.noTransportAddress(.lan):
            return LocalizedStringResource(
                "welcome.joinExisting.error.noLAN",
                defaultValue: "This Mac does not have a usable LAN address right now.",
                comment: "Error shown when the local daemon cannot find a LAN address for pair-machine staging."
            )
        case DaemonPairMachineStageError.noTransportAddress(.tailscale):
            return LocalizedStringResource(
                "welcome.joinExisting.error.noTailscale",
                defaultValue: "Tailscale is not available on this Mac yet.",
                comment: "Error shown when the local daemon cannot find a Tailscale address for pair-machine staging."
            )
        case DaemonPairMachineStageError.alreadyPaired:
            return LocalizedStringResource(
                "welcome.joinExisting.error.alreadyPaired",
                defaultValue: "This Mac is already part of a Soyeht.",
                comment: "Error shown when the user tries to stage join-existing QR after the Mac has local household state."
            )
        case DaemonPairMachineStageError.daemonError:
            return LocalizedStringResource(
                "welcome.joinExisting.error.daemon",
                defaultValue: "Soyeht could not prepare this QR. Try again.",
                comment: "Generic daemon failure while staging a join-existing-Soyeht QR."
            )
        default:
            return LocalizedStringResource(
                "welcome.joinExisting.error.invalidResponse",
                defaultValue: "Soyeht returned an unreadable QR response. Try again.",
                comment: "Protocol failure while staging a join-existing-Soyeht QR."
            )
        }
    }

    private static func formatRemaining(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes):\(String(format: "%02d", secs))"
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
