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
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear(perform: reload)
        .onChange(of: isEnabled) { newValue in
            applyPreference(newValue)
        }
    }

    private func reload() {
        household = try? sessionStore.load()
        if let household {
            isEnabled = HouseholdApplePushPreference.isEnabled(for: household.householdId)
        }
    }

    private func applyPreference(_ newValue: Bool) {
        guard let household else { return }
        HouseholdApplePushPreference.setEnabled(newValue, for: household.householdId)
        isApplying = true

        Task {
            do {
                if newValue {
                    _ = try await APNSRegistrationCoordinator.shared.resume()
                } else {
                    await APNSRegistrationCoordinator.shared.suspend()
                }
            } catch {
                householdApplePushSettingsLogger.error("Apple Push Service preference apply failed: \(String(describing: error), privacy: .public)")
            }
            await MainActor.run {
                isApplying = false
            }
        }
    }
}
