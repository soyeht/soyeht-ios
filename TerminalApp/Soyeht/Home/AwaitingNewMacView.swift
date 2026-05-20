import SwiftUI
import Network
import os
import SoyehtCore

private let awaitingNewMacLogger = Logger(subsystem: "com.soyeht.mobile", category: "awaiting-new-mac")

/// US-G: presented from `AddDevicePickerView` when the user wants to
/// add a Mac to the household that already includes this iPhone and
/// (typically) a Linux box. The iPhone holds no `hh_priv` locally, so
/// it orchestrates the three-step dance:
///   1. POST /bootstrap/accept-household → fresh Mac, get a JoinChallenge
///   2. POST /api/v1/household/sign-machine-cert → existing member engine,
///      get a household-signed MachineCert + challenge signature
///   3. POST /bootstrap/accept-household/confirm → fresh Mac, deliver
/// The fresh Mac never sees the iPhone-Linux call; the Linux engine
/// never sees the fresh Mac directly. All consent stays on the iPhone.
struct AwaitingNewMacView: View {
    let invitation: SetupInvitationPayload
    let household: ActiveHouseholdState
    let onCompleted: () -> Void
    let onCancel: () -> Void

    @StateObject private var viewModel: AwaitingNewMacViewModel

    init(
        invitation: SetupInvitationPayload,
        household: ActiveHouseholdState,
        onCompleted: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.invitation = invitation
        self.household = household
        self.onCompleted = onCompleted
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: AwaitingNewMacViewModel(
            invitation: invitation,
            household: household
        ))
    }

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()
            VStack(spacing: 0) {
                dismissBar
                Spacer()
                content
                    .padding(.horizontal, 32)
                Spacer()
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear { viewModel.start(onCompleted: onCompleted) }
        .onDisappear { viewModel.stop() }
    }

    private var dismissBar: some View {
        HStack {
            Button(action: onCancel) {
                Text(LocalizedStringResource(
                    "awaitingNewMac.cancel",
                    defaultValue: "Cancel",
                    comment: "Cancel button on the Add Mac waiting screen."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .looking:
            lookingContent
        case .orchestrating:
            orchestratingContent
        case .success:
            successContent
        case .failure(let message):
            failureContent(message: message)
        }
    }

    private var lookingContent: some View {
        VStack(spacing: 32) {
            pulsatingRadar
            VStack(spacing: 10) {
                Text(LocalizedStringResource(
                    "awaitingNewMac.looking.title",
                    defaultValue: "Looking for your Mac...",
                    comment: "Title shown while the iPhone publishes a setup invitation and waits for a fresh Mac to claim it."
                ))
                .font(OnboardingFonts.heading)
                .foregroundColor(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "awaitingNewMac.looking.subtitle",
                    defaultValue: "Open Soyeht on the Mac you want to add to \(household.householdName). I'll do the rest.",
                    comment: "Subtitle on the Add Mac waiting screen."
                ))
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)
            }
        }
    }

    private var orchestratingContent: some View {
        VStack(spacing: 32) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.4)
                .tint(BrandColors.accentGreen)
            Text(LocalizedStringResource(
                "awaitingNewMac.orchestrating.title",
                defaultValue: "Adding your Mac to \(household.householdName)...",
                comment: "Title shown while iPhone runs the cert-issue dance with Linux + Mac."
            ))
            .font(OnboardingFonts.heading)
            .foregroundColor(BrandColors.textPrimary)
            .multilineTextAlignment(.center)
        }
    }

    private var successContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(BrandColors.accentGreen)
                .accessibilityHidden(true)
            Text(LocalizedStringResource(
                "awaitingNewMac.success.title",
                defaultValue: "Mac added",
                comment: "Title shown when the Mac successfully joins the household."
            ))
            .font(OnboardingFonts.heading)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func failureContent(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(BrandColors.accentAmber)
                .accessibilityHidden(true)
            Text(LocalizedStringResource(
                "awaitingNewMac.failure.title",
                defaultValue: "Couldn't add this Mac",
                comment: "Title shown when the Add Mac flow fails."
            ))
            .font(OnboardingFonts.heading)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            Text(verbatim: message)
                .font(OnboardingFonts.footnote)
                .foregroundColor(BrandColors.textMuted)
                .multilineTextAlignment(.center)

            Button(action: { viewModel.retry() }) {
                Text(LocalizedStringResource(
                    "awaitingNewMac.failure.retry",
                    defaultValue: "Try again",
                    comment: "Retry CTA on the Add Mac failure screen."
                ))
                .font(OnboardingFonts.bodyBold)
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(BrandColors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var pulsatingRadar: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                PulseRing(delay: Double(i) * 0.5)
            }
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 36))
                .foregroundColor(BrandColors.accentGreen)
        }
        .frame(width: 120, height: 120)
        .accessibilityHidden(true)
    }
}

private struct PulseRing: View {
    let delay: Double
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(BrandColors.accentGreen.opacity(opacity), lineWidth: 1.5)
            .scaleEffect(scale)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeOut(duration: 1.8)
                    .delay(delay)
                    .repeatForever(autoreverses: false)
                ) {
                    scale = 1.4
                    opacity = 0
                }
            }
    }
}

// MARK: - ViewModel

@MainActor
final class AwaitingNewMacViewModel: ObservableObject {
    enum Phase: Equatable {
        case looking
        case orchestrating
        case success
        case failure(message: String)
    }

    @Published private(set) var phase: Phase = .looking

    private let invitation: SetupInvitationPayload
    private let household: ActiveHouseholdState

    private let publisher: SetupInvitationPublisher
    private var onCompleted: (() -> Void)?
    private var orchestrationTask: Task<Void, Never>?
    private var alreadyOrchestrating = false

    init(invitation: SetupInvitationPayload, household: ActiveHouseholdState) {
        self.invitation = invitation
        self.household = household
        self.publisher = SetupInvitationPublisher(invitation: invitation)
    }

    func start(onCompleted: @escaping () -> Void) {
        self.onCompleted = onCompleted
        publisher.onMacClaimed = { [weak self] claim in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Defense in depth: only accept claims when we're still
                // actively looking. After a failure or while a dance is
                // running, a second Mac re-announcing on the Tailnet must
                // NOT flip the UI back into orchestration without the user
                // explicitly tapping "Try again".
                guard self.phase == .looking, !self.alreadyOrchestrating else { return }
                // The fresh Mac may also publish an existing-house card
                // (it's not really "ours" then). Don't accept-household
                // into a Mac that already belongs to someone else.
                guard claim.existingHouse == nil else {
                    self.phase = .failure(message: String(localized: LocalizedStringResource(
                        "awaitingNewMac.failure.notFresh",
                        defaultValue: "That Mac already has a home. Choose a different Mac or reset it first.",
                        comment: "Error shown when the Mac being added is not in a fresh Uninitialized state."
                    )))
                    return
                }
                self.alreadyOrchestrating = true
                self.phase = .orchestrating
                self.orchestrationTask = Task { [weak self] in
                    await self?.runDance(claim: claim)
                }
            }
        }
        publisher.start()
    }

    func stop() {
        publisher.stop()
        publisher.onMacClaimed = nil
        orchestrationTask?.cancel()
        orchestrationTask = nil
    }

    func retry() {
        alreadyOrchestrating = false
        orchestrationTask?.cancel()
        orchestrationTask = nil
        phase = .looking
    }

    private func runDance(claim: SetupInvitationDirectClaim) async {
        let macEngineURL = claim.macEngineURL
        let hostname = hostnameForCert(claim: claim, macURL: macEngineURL)

        do {
            // Step 1 — fresh Mac: accept-household
            let accept = BootstrapAcceptHouseholdClient(baseURL: macEngineURL)
            let acceptResp = try await accept.acceptHousehold(
                householdId: household.householdId,
                householdPublicKey: household.householdPublicKey,
                householdName: household.householdName,
                invitationToken: claim.token
            )
            try Task.checkCancellation()

            // Step 2 — existing member engine: sign machine cert
            let ownerIdentity = try loadOwnerIdentity()
            let popSigner = HouseholdPoPSigner(ownerIdentity: ownerIdentity)
            let signer = HouseholdSignMachineCertClient(
                baseURL: household.endpoint,
                popSigner: popSigner
            )
            let signed = try await signer.signMachineCert(
                subject: HouseholdSignMachineCertSubject(
                    machineId: acceptResp.machineId,
                    machinePublicKey: acceptResp.machinePublicKey,
                    hostname: hostname,
                    platform: .macos
                ),
                challenge: acceptResp.joinChallenge
            )
            try Task.checkCancellation()

            // Step 3 — fresh Mac: confirm with signed cert + challenge sig
            let confirm = BootstrapAcceptHouseholdConfirmClient(baseURL: macEngineURL)
            let final = try await confirm.confirm(
                machineId: signed.machineId,
                machineCert: signed.machineCert,
                challengeSig: signed.challengeSignature
            )
            try Task.checkCancellation()

            guard final.bootstrapState == "ready" else {
                throw AwaitingNewMacError.unexpectedFinalState(final.bootstrapState)
            }

            // If the Mac also published a local-pairing envelope (engine
            // address/ports for direct attach), persist it so the home
            // list reflects the new Mac right away.
            if let pairing = claim.macLocalPairing {
                let store = PairedMacsStore.shared
                store.storeSecret(pairing.secret, for: pairing.macID)
                store.upsertMac(
                    macID: pairing.macID,
                    name: pairing.macName,
                    host: pairing.host,
                    presencePort: pairing.presencePort,
                    attachPort: pairing.attachPort
                )
                PairedMacRegistry.shared.reconcileClients()
            }

            // `runDance` is reached only through an @MainActor-isolated
            // call site (the class is @MainActor), so direct @State
            // mutation is safe — no need for `await MainActor.run`.
            self.phase = .success
            try? await Task.sleep(for: .milliseconds(600))
            self.onCompleted?()
        } catch is CancellationError {
            // View teardown / retry — leave phase as-is
        } catch let error as BootstrapError {
            fail(with: error.localizedDescription)
        } catch let error as HouseholdPoPError {
            fail(with: popErrorMessage(error))
        } catch {
            awaitingNewMacLogger.error(
                "soyeht_diag accept_household_dance_failed error=\(String(describing: error), privacy: .public)"
            )
            fail(with: String(localized: LocalizedStringResource(
                "awaitingNewMac.failure.generic",
                defaultValue: "Something went wrong. Try again.",
                comment: "Generic Add Mac failure message."
            )))
        }
    }

    private func fail(with message: String) {
        self.alreadyOrchestrating = false
        self.phase = .failure(message: message)
    }

    private func loadOwnerIdentity() throws -> any OwnerIdentitySigning {
        let provider = SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
        return try provider.loadOwnerIdentity(
            keyReference: household.signingKeyReference,
            publicKey: household.signingPublicKey,
            personId: household.ownerPersonId
        )
    }

    private func hostnameForCert(claim: SetupInvitationDirectClaim, macURL: URL) -> String {
        if let pairing = claim.macLocalPairing,
           !pairing.macName.isEmpty {
            return Self.truncateToUTF8Bytes(pairing.macName, maxBytes: 64)
        }
        if let host = macURL.host, !host.isEmpty {
            return Self.truncateToUTF8Bytes(host, maxBytes: 64)
        }
        return "Mac"
    }

    /// Engine contract caps `hostname` at 64 UTF-8 bytes (not characters).
    /// `String.prefix(64)` counts Characters, so a single emoji / CJK
    /// glyph / accented Latin letter that takes 2–4 bytes can overflow
    /// silently and trigger a server-side `invalid_subject` 400. Walk
    /// scalars accumulating UTF-8 byte cost and cut on the boundary.
    static func truncateToUTF8Bytes(_ value: String, maxBytes: Int) -> String {
        var bytesUsed = 0
        var endIndex = value.startIndex
        for index in value.indices {
            let nextByteCost = value[index].utf8.count
            if bytesUsed + nextByteCost > maxBytes { break }
            bytesUsed += nextByteCost
            endIndex = value.index(after: index)
        }
        return String(value[..<endIndex])
    }

    private func popErrorMessage(_ error: HouseholdPoPError) -> String {
        switch error {
        case .biometryCanceled:
            return String(localized: LocalizedStringResource(
                "awaitingNewMac.failure.biometryCanceled",
                defaultValue: "Authentication cancelled. Try again to add this Mac.",
                comment: "Error shown when the user cancels the biometric prompt during Add Mac."
            ))
        case .noActiveHousehold, .ownerIdentityUnavailable, .invalidLocalCert:
            return String(localized: LocalizedStringResource(
                "awaitingNewMac.failure.identityUnavailable",
                defaultValue: "Your identity isn't available right now. Reopen the app and try again.",
                comment: "Error shown when the owner identity key cannot be loaded for Add Mac."
            ))
        case .missingCaveat, .signingFailed:
            return String(localized: LocalizedStringResource(
                "awaitingNewMac.failure.signingFailed",
                defaultValue: "Couldn't sign the request. Try again.",
                comment: "Error shown when PoP signing fails during Add Mac."
            ))
        }
    }
}

// MARK: - Errors

private enum AwaitingNewMacError: Error, LocalizedError {
    case unexpectedFinalState(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedFinalState(let state):
            return "Unexpected final state from Mac: \(state)"
        }
    }
}
