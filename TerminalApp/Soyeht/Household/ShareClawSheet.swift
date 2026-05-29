import SwiftUI
import SoyehtCore
#if canImport(UIKit)
import UIKit
import CoreImage.CIFilterBuiltins
#endif

/// Owner-side "Share" sheet for a claw / host (e.g. the Mac terminal).
///
/// Mints a real, owner-PoP-authenticated invite via `ClawShareComposer`
/// (`POST /api/v1/claw-share/invites`) and hands the resulting `soyeht://…`
/// link to the system share sheet. The link is only shown **after** a
/// successful mint — there is no fake/placeholder link. The friend redeems it
/// through the existing deep-link flow (`ClawShareInviteCenter`).
///
/// Copy is intentionally jargon-free: no "mint", "slot", "PoP", or "claw_id".
struct ShareClawSheet: View {
    /// The claw/host id the engine shares (the instance id, e.g. `mac-host`).
    let clawId: String
    /// Human name shown to the owner (e.g. "Mac Host").
    let clawName: String
    /// The Mac/server hosting the claw; `nil` falls back to the active household.
    let endpoint: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var duration: ShareDuration = .oneDay
    @State private var phase: Phase = .ready

    private let composer = ClawShareComposer(apiClient: .shared)

    enum ShareDuration: CaseIterable, Identifiable {
        case oneHour, oneDay, oneWeek
        var id: Self { self }
        var seconds: UInt64 {
            switch self {
            case .oneHour: return 3600
            case .oneDay: return 86_400
            case .oneWeek: return 604_800
            }
        }
        var label: String {
            switch self {
            case .oneHour: return "1 hour"
            case .oneDay: return "1 day"
            case .oneWeek: return "1 week"
            }
        }
    }

    enum Phase {
        case ready
        case working
        case shared(ClawShareMintResult)
        case failed(String)
    }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch phase {
                        case .ready, .working:
                            composeSection
                        case let .shared(result):
                            sharedSection(result)
                        case let .failed(message):
                            failureSection(message)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("soyeht.clawShare.shareSheet")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: { dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(Typography.iconNav)
                    Text(verbatim: "share \(clawName)") // i18n-exempt: owner-only Share slice, pre-localization
                        .font(Typography.monoBodyLargeMedium)
                }
                .foregroundColor(SoyehtTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "person.badge.plus").foregroundColor(SoyehtTheme.accentGreen)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Compose

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: "Invite someone to use this terminal. They'll have access until the invite expires, and you can stop sharing at any time.") // i18n-exempt: owner-only Share slice, pre-localization
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "expires after") // i18n-exempt: owner-only Share slice
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.textComment)
                Picker("", selection: $duration) {
                    ForEach(ShareDuration.allCases) { option in
                        Text(verbatim: option.label).tag(option) // i18n-exempt
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isWorking)
                .accessibilityIdentifier("soyeht.clawShare.duration")
            }

            Button(action: { Task { await generate() } }) {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().tint(SoyehtTheme.accentGreen) }
                    Text(verbatim: isWorking ? "creating…" : "create invite link") // i18n-exempt
                        .font(Typography.monoLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SoyehtTheme.accentGreen, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .foregroundColor(SoyehtTheme.accentGreen)
            .disabled(isWorking)
            .accessibilityIdentifier("soyeht.clawShare.generate")
        }
    }

    private var isWorking: Bool { if case .working = phase { return true }; return false }

    // MARK: - Shared (link ready)

    private func sharedSection(_ result: ClawShareMintResult) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: "invite link is ready") // i18n-exempt
                .font(Typography.monoLabel)
                .foregroundColor(SoyehtTheme.textComment)

            if let url = URL(string: result.uri) {
                #if canImport(UIKit)
                if let qr = Self.qrImage(for: result.uri) {
                    HStack {
                        Spacer()
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                            .accessibilityIdentifier("soyeht.clawShare.qr")
                        Spacer()
                    }
                }
                #endif

                Text(verbatim: result.uri) // i18n-exempt: the link itself
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Text(verbatim: "share…") // i18n-exempt
                            .font(Typography.monoLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SoyehtTheme.accentGreen, lineWidth: 1))
                    }
                    .foregroundColor(SoyehtTheme.accentGreen)
                    .accessibilityIdentifier("soyeht.clawShare.shareLink")

                    Button(action: { copyLink(result.uri) }) {
                        Text(verbatim: "copy link") // i18n-exempt
                            .font(Typography.monoLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SoyehtTheme.textSecondary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .accessibilityIdentifier("soyeht.clawShare.copy")
                }
            }

            Text(verbatim: "Stop sharing anytime from this screen.") // i18n-exempt
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textComment)
        }
    }

    // MARK: - Failure

    private func failureSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: message) // i18n-exempt: friendly error text built below
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textWarning)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { phase = .ready }) {
                Text(verbatim: "try again") // i18n-exempt
                    .font(Typography.monoLabel)
                    .foregroundColor(SoyehtTheme.accentGreen)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func generate() async {
        phase = .working
        do {
            let result = try await composer.mintInvite(
                clawId: clawId,
                ttlSeconds: duration.seconds,
                endpoint: endpoint
            )
            phase = .shared(result)
        } catch {
            phase = .failed(Self.friendlyMessage(for: error))
        }
    }

    private func copyLink(_ uri: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = uri
        #endif
    }

    /// Map low-level errors to honest, non-technical copy.
    static func friendlyMessage(for error: Error) -> String {
        if error is ClawShareMintError {
            return "Couldn't create the invite — the host sent back something unexpected. Please try again."
        }
        return "Couldn't create the invite. Check that this Mac is online and that you have permission to share it, then try again."
    }

    #if canImport(UIKit)
    static func qrImage(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    #endif
}
