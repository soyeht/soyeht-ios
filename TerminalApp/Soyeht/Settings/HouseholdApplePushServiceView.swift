import SwiftUI
import SoyehtCore
import os

private let householdApplePushSettingsLogger = Logger(
    subsystem: "com.soyeht.mobile",
    category: "household-apple-push-settings"
)

struct HouseholdApplePushServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var household: ActiveHouseholdState?
    @State private var isEnabled = true
    @State private var isApplying = false
    @State private var showApplyFailureBanner = false
    /// Set when we programmatically revert `isEnabled` after a failure so
    /// the resulting `onChange(of: isEnabled)` callback short-circuits
    /// instead of re-entering `applyPreference` and looping the user
    /// through the same failed call. Also flipped during `reload()` so a
    /// view-lifecycle-driven `isEnabled` write (loading the persisted
    /// value) does not masquerade as a user toggle.
    @State private var suppressNextChange = false
    /// Last value the runtime has actually committed to APNS — i.e. the
    /// ground truth we revert to when an apply call fails. Tracking this
    /// explicitly defends the rollback path against any non-user driver
    /// of `isEnabled` (e.g. `reload()`, future programmatic writes); the
    /// previous version derived `priorValue = !newValue`, which silently
    /// flipped the meaning when the toggle was set non-interactively
    /// (PR #53 review F2#1).
    @State private var lastAppliedValue = true

    private let sessionStore = HouseholdSessionStore()

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }

                    Text("settings.row.householdApplePushService")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("settings.householdApplePush.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: "bell.badge")
                                    .font(Typography.sansCard)
                                    .foregroundColor(isEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                                    .frame(width: 20)

                                Text("settings.row.householdApplePushService")
                                    .font(Typography.monoCardBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Spacer()

                                Toggle("", isOn: $isEnabled)
                                    .labelsHidden()
                                    .tint(SoyehtTheme.historyGreen)
                                    .disabled(household == nil || isApplying)
                                    .accessibilityIdentifier(AccessibilityID.Settings.householdApplePushToggle)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .overlay(
                            Rectangle()
                                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                        )

                        if household == nil {
                            Text("settings.householdApplePush.unavailable")
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textTertiary)
                        }

                        if showApplyFailureBanner {
                            Text("settings.householdApplePush.applyFailed")
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.accentRed)
                                .accessibilityIdentifier(AccessibilityID.Settings.householdApplePushFailureBanner)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear(perform: reload)
        .onChange(of: isEnabled) { newValue in
            if suppressNextChange {
                suppressNextChange = false
                return
            }
            applyPreference(newValue)
        }
    }

    private func reload() {
        household = try? sessionStore.load()
        guard let household else { return }
        let persisted = HouseholdApplePushPreference.isEnabled(for: household.householdId)
        // The reload path mutates `isEnabled` to surface the persisted
        // value; that mutation is not a user intent and must not drive
        // `applyPreference`, otherwise a transient APNS apply failure
        // would roll back to a fabricated "prior" that matches neither
        // persistence nor what the operator chose.
        if isEnabled != persisted {
            suppressNextChange = true
            isEnabled = persisted
        }
        lastAppliedValue = persisted
    }

    private func applyPreference(_ newValue: Bool) {
        guard let household else { return }
        let priorValue = lastAppliedValue
        HouseholdApplePushPreference.setEnabled(newValue, for: household.householdId)
        lastAppliedValue = newValue
        showApplyFailureBanner = false
        isApplying = true

        Task { @MainActor in
            do {
                if newValue {
                    _ = try await APNSRegistrationCoordinator.shared.resume()
                } else {
                    await APNSRegistrationCoordinator.shared.suspend()
                }
            } catch {
                householdApplePushSettingsLogger.error("Apple Push Service preference apply failed: \(String(describing: error), privacy: .public)")
                // Roll back the durable preference, the toggle, and the
                // ground-truth tracker in lockstep so the persistent
                // state, UI, and the next `applyPreference` baseline all
                // converge on `priorValue`. The follow-up `onChange`
                // callback (driven by our own revert) is suppressed via
                // `suppressNextChange` to break the loop.
                HouseholdApplePushPreference.setEnabled(priorValue, for: household.householdId)
                lastAppliedValue = priorValue
                suppressNextChange = true
                isEnabled = priorValue
                showApplyFailureBanner = true
            }
            isApplying = false
        }
    }
}
