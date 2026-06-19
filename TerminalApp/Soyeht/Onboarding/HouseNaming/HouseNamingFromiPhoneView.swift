import SwiftUI
import SoyehtCore

/// iPhone-side house naming for case B (T065).
/// Same UX as Mac's HouseNamingView, but POSTs the name to the discovered Mac engine
/// via `POST /bootstrap/initialize`. Shows an in-progress state while the POST is in flight.
struct HouseNamingFromiPhoneView: View {
    let macEngineBaseURL: URL
    let claimToken: Data
    let localPairing: SetupInvitationMacLocalPairing?
    let onNamed: () -> Void
    let onBack: () -> Void

    @State private var houseName: String = Self.suggestedName()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submitTask: Task<Void, Never>?
    @State private var showSlowHint: Bool = false
    @State private var slowHintTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    /// Delay before revealing the "taking longer than expected" hint + cancel button.
    private static let slowHintDelay: Duration = .seconds(5)

    private static let maxLength = 32
    private static let forbiddenChars = CharacterSet(charactersIn: "/:\\*?\"<>|")

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            if isSubmitting {
                submittingOverlay
            } else {
                namingContent
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .onAppear { isFocused = true }
        .onDisappear {
            submitTask?.cancel()
            slowHintTask?.cancel()
        }
    }

    private var namingContent: some View {
        VStack(spacing: 0) {
            backBar

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LocalizedStringResource(
                            "houseNamingPhone.title",
                            defaultValue: "What do you want to call your home?",
                            comment: "House naming screen title (iPhone side, case B)."
                        ))
                        .font(OnboardingFonts.heading)
                        .foregroundColor(BrandColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringResource(
                            "houseNamingPhone.subtitle",
                            defaultValue: "You can change this later.",
                            comment: "House naming subtitle reassuring name is changeable."
                        ))
                        .font(OnboardingFonts.subheadline)
                        .foregroundColor(BrandColors.textMuted)
                    }

                    nameField

                    if let error = errorMessage {
                        Text(verbatim: error)
                            .font(OnboardingFonts.footnote)
                            .foregroundColor(BrandColors.accentAmber)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 40)
            }

            Spacer(minLength: 0)

            ctaBar
        }
    }

    private var backBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .semibold))
                    Text(LocalizedStringResource(
                        "houseNamingPhone.back",
                        defaultValue: "Back",
                        comment: "Back button on house naming (iPhone side)."
                    ))
                    .font(OnboardingFonts.subheadline)
                }
                .foregroundColor(BrandColors.textMuted)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "houseNamingPhone.field.placeholder",
                text: $houseName
            )
            .focused($isFocused)
            .font(Font.title2.weight(.medium))
            .foregroundColor(BrandColors.textPrimary)
            .submitLabel(.done)
            .onChange(of: houseName) { new in
                let cleaned = new.unicodeScalars
                    .filter { !Self.forbiddenChars.contains($0) }
                    .map { Character($0) }
                let clamped = String(cleaned.prefix(Self.maxLength))
                if clamped != new { houseName = clamped }
                errorMessage = nil
            }
            .onSubmit { guard isValid else { return }; submit() }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(BrandColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? BrandColors.accentGreen : BrandColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(Text(LocalizedStringResource(
                "houseNamingPhone.field.a11y",
                defaultValue: "Home name, \(houseName.count) of \(Self.maxLength) characters",
                comment: "House name field VoiceOver label with char count."
            )))

            HStack {
                Spacer()
                Text(LocalizedStringResource(
                    "houseNamingPhone.charCount",
                    defaultValue: "\(houseName.count)/\(Self.maxLength)",
                    comment: "Character count for house name field."
                ))
                .font(.system(size: 12))
                .foregroundColor(houseName.count >= Self.maxLength ? BrandColors.accentAmber : BrandColors.textMuted)
                .accessibilityHidden(true)
            }
        }
    }

    private var ctaBar: some View {
        VStack(spacing: 0) {
            Divider().background(BrandColors.border)
            Button(action: submit) {
                Text(LocalizedStringResource(
                    "houseNamingPhone.cta",
                    defaultValue: "Create Home",
                    comment: "CTA to submit house name from iPhone."
                ))
                .font(OnboardingFonts.bodyBold)
                .foregroundColor(BrandColors.buttonTextOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isValid ? BrandColors.accentGreen : BrandColors.border)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!isValid)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(BrandColors.surfaceDeep)
    }

    private var submittingOverlay: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.4)
                .tint(BrandColors.accentGreen)

            Text(LocalizedStringResource(
                "houseNamingPhone.submitting",
                defaultValue: "Waiting for your Mac to create the home...",
                comment: "In-progress message while Mac creates the house. Ellipsis indicates ongoing."
            ))
            .font(OnboardingFonts.body)
            .foregroundColor(BrandColors.textMuted)
            .multilineTextAlignment(.center)

            if showSlowHint {
                VStack(spacing: 12) {
                    Text(LocalizedStringResource(
                        "houseNamingPhone.submitting.slowHint",
                        defaultValue: "This is taking longer than usual.",
                        comment: "Hint shown after 5s while the Mac engine has not responded to bootstrap/initialize."
                    ))
                    .font(OnboardingFonts.footnote)
                    .foregroundColor(BrandColors.accentAmber)
                    .multilineTextAlignment(.center)

                    Button(action: cancelSubmission) {
                        Text(LocalizedStringResource(
                            "houseNamingPhone.submitting.cancel",
                            defaultValue: "Cancel",
                            comment: "Button to cancel the in-flight bootstrap/initialize request and return to the naming form."
                        ))
                        .font(OnboardingFonts.bodyBold)
                        .foregroundColor(BrandColors.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(BrandColors.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(BrandColors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .padding(40)
        .animation(.easeInOut(duration: 0.2), value: showSlowHint)
        .accessibilityLabel(Text(LocalizedStringResource(
            "houseNamingPhone.submitting.a11y",
            defaultValue: "Your Mac is creating your home...",
            comment: "VoiceOver label for the in-progress house creation state."
        )))
    }

    // MARK: - Logic

    private var isValid: Bool {
        let trimmed = houseName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.count <= Self.maxLength
            && !houseName.unicodeScalars.contains { Self.forbiddenChars.contains($0) }
    }

    private func submit() {
        let trimmed = houseName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        submitTask?.cancel()
        slowHintTask?.cancel()
        isSubmitting = true
        showSlowHint = false
        errorMessage = nil

        slowHintTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.slowHintDelay)
                showSlowHint = true
            } catch {
                // cancelled — leave showSlowHint as-is
            }
        }
        // Capture the just-assigned slow-hint Task into a local so the
        // submit Task's defer cancels the right one even if the user
        // hits Cancel and retries before the defer fires (a fresh
        // `submit()` would otherwise overwrite `slowHintTask` and the
        // stale `defer` reading @State would cancel the *new* timer).
        let pendingSlowHint = slowHintTask

        submitTask = Task {
            defer {
                pendingSlowHint?.cancel()
            }
            do {
                let token = try SetupInvitationToken(bytes: claimToken)
                let client = BootstrapInitializeClient(baseURL: macEngineBaseURL)
                let response = try await client.initialize(name: trimmed, claimToken: token)
                guard let pairURL = URL(string: response.pairQrUri) else {
                    throw HouseholdPairingError.invalidQR
                }
                _ = try await HouseholdPairingService(
                    browser: DirectHouseholdPairingBrowser(
                        endpoint: macEngineBaseURL,
                        householdName: trimmed
                    ),
                    keyProvider: SecureEnclaveOwnerIdentityKeyProvider(protection: .deviceUnlocked)
                ).pair(
                    url: pairURL,
                    displayName: await MainActor.run { HouseholdOwnerDisplayName.defaultName() }
                )
                await MainActor.run {
                    if let localPairing {
                        installMacLocalPairing(localPairing)
                    }
                }
                try Task.checkCancellation()
                await MainActor.run { onNamed() }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    showSlowHint = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelSubmission() {
        submitTask?.cancel()
        slowHintTask?.cancel()
        isSubmitting = false
        showSlowHint = false
        errorMessage = String(
            localized: "houseNamingPhone.submit.timeoutError",
            defaultValue: "Connection took too long, try again.",
            comment: "Error shown after user cancels a slow bootstrap/initialize request."
        )
    }

    private static func suggestedName() -> String {
        let deviceName = UIDevice.current.name
        let firstName = deviceName.components(separatedBy: .whitespaces).first ?? deviceName
        let prefix = String(localized: "houseNamingPhone.suggestedPrefix", defaultValue: "Home")
        return "\(prefix) \(firstName)"
    }
}

private struct DirectHouseholdPairingBrowser: HouseholdBonjourBrowsing {
    let endpoint: URL
    let householdName: String

    func firstMatchingCandidate(
        for qr: PairDeviceQR,
        timeout: TimeInterval
    ) async throws -> HouseholdDiscoveryCandidate {
        HouseholdDiscoveryCandidate(
            endpoint: endpoint,
            householdId: qr.householdId,
            householdName: householdName,
            machineId: nil,
            pairingState: "device",
            shortNonce: qr.shortNonce
        )
    }
}
