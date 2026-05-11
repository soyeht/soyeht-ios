import SwiftUI
import SoyehtCore

struct HouseholdApplePushServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HouseholdApplePushServiceViewModel

    @MainActor
    init() {
        self.init(model: HouseholdApplePushServiceViewModel())
    }

    @MainActor
    init(model: HouseholdApplePushServiceViewModel) {
        self._model = StateObject(wrappedValue: model)
    }

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
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "common.accessibility.back",
                        defaultValue: "Back",
                        comment: "VoiceOver label for the back chevron in custom navigation headers."
                    )))

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
                                    .foregroundColor(model.isEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)

                                Text("settings.row.householdApplePushService")
                                    .font(Typography.monoCardBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Spacer()

                                Toggle("", isOn: $model.isEnabled)
                                    .labelsHidden()
                                    .tint(SoyehtTheme.historyGreen)
                                    .disabled(model.household == nil || model.isApplying)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            // Combine the row into a single accessibility element so VoiceOver,
                            // Switch Control, and Voice Control land on one target announced as
                            // "Apple Push Service, switch button, on/off" instead of stopping on
                            // icon → text → toggle separately. The decorative bell icon stays
                            // hidden so its auto-label ("bell badge") doesn't pollute the row's
                            // combined label; the visible Text supplies the row name and the
                            // Toggle contributes the switch trait + on/off value automatically.
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(AccessibilityID.Settings.householdApplePushToggle)
                        }
                        .overlay(
                            Rectangle()
                                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                        )

                        if model.household == nil {
                            Text("settings.householdApplePush.unavailable")
                                .font(Typography.monoSmall)
                                .foregroundColor(SoyehtTheme.textTertiary)
                        }

                        if model.showApplyFailureBanner {
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
        .onAppear { model.reload() }
        .onChange(of: model.isEnabled) { newValue in
            model.handleToggle(newValue)
        }
    }
}
