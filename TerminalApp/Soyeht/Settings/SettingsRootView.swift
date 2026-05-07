import SwiftUI
import SoyehtCore

struct SettingsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
    @State private var cursorStyleLabel = CursorStyleHelper.displayName(for: TerminalPreferences.shared.cursorStyle)
    @State private var hapticLabel = TerminalPreferences.shared.hapticEnabled
        ? String(localized: "settings.value.on")
        : String(localized: "settings.value.off")
    @State private var colorThemeLabel: String = TerminalColorTheme.active.displayName
    @State private var voiceLabel = TerminalPreferences.shared.voiceInputEnabled
        ? String(localized: "settings.value.on")
        : String(localized: "settings.value.off")
    @State private var shortcutBarLabel = TerminalPreferences.shared.shortcutBarLabel
    @State private var activeHousehold: ActiveHouseholdState?
    @State private var householdApplePushEnabled = true
    @State private var householdApplePushLabel = String(localized: "settings.value.on")

    private let householdSessionStore = HouseholdSessionStore()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SoyehtTheme.bgPrimary.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    // Nav bar
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(Typography.sansNav)
                                .foregroundColor(SoyehtTheme.historyGray)
                        }

                        Text("settings.title")
                            .font(Typography.monoBodyMedium)
                            .foregroundColor(SoyehtTheme.textPrimary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // Content
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("settings.section.terminal")
                                .font(Typography.monoLabel)
                                .foregroundColor(SoyehtTheme.historyGray)

                            Text("settings.section.terminal.description")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textTertiary)

                            Spacer().frame(height: 4)

                            // Settings list
                            VStack(spacing: 0) {
                                Button { path.append(SettingsRoute.colorTheme) } label: {
                                    SettingsRow(icon: "paintpalette", label: "settings.row.colorTheme", value: colorThemeLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.colorThemeButton)
                                divider
                                Button { path.append(SettingsRoute.fontSize) } label: {
                                    SettingsRow(icon: "textformat.size", label: "settings.row.fontSize", value: fontSizeLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.fontSizeButton)
                                divider
                                Button { path.append(SettingsRoute.cursorStyle) } label: {
                                    SettingsRow(icon: "character.cursor.ibeam", label: "settings.row.cursorStyle", value: cursorStyleLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.cursorStyleButton)
                                divider
                                Button { path.append(SettingsRoute.shortcutBar) } label: {
                                    SettingsRow(icon: "keyboard", label: "settings.row.shortcutBar", value: shortcutBarLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.shortcutBarButton)
                                divider
                                Button { path.append(SettingsRoute.hapticFeedback) } label: {
                                    SettingsRow(
                                        icon: "iphone.radiowaves.left.and.right",
                                        label: "settings.row.hapticFeedback",
                                        value: hapticLabel,
                                        valueColor: TerminalPreferences.shared.hapticEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
                                    )
                                }
                                .buttonStyle(.plain)
                                divider
                                Button { path.append(SettingsRoute.voiceInput) } label: {
                                    SettingsRow(
                                        icon: "mic",
                                        label: "settings.row.voiceInput",
                                        value: voiceLabel,
                                        valueColor: TerminalPreferences.shared.voiceInputEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
                                    )
                                }
                                .buttonStyle(.plain)
                                divider
                                Button { path.append(SettingsRoute.pairedMacs) } label: {
                                    SettingsRow(
                                        icon: "desktopcomputer",
                                        label: "settings.row.pairedMacs",
                                        value: "\(PairedMacsStore.shared.macs.count)"
                                    )
                                }
                                .buttonStyle(.plain)
                                if activeHousehold != nil {
                                    divider
                                    Button { path.append(SettingsRoute.householdApplePushService) } label: {
                                        SettingsRow(
                                            icon: "bell.badge",
                                            label: "settings.row.householdApplePushService",
                                            value: householdApplePushLabel,
                                            valueColor: householdApplePushEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.Settings.householdApplePushButton)
                                }
                            }
                            .overlay(
                                Rectangle()
                                    .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .fontSize:
                    FontSizeView()
                case .cursorStyle:
                    CursorStyleView()
                case .customColor:
                    CustomColorPickerView()
                case .hapticFeedback:
                    HapticZoneView()
                case .colorTheme:
                    ColorThemeView()
                case .voiceInput:
                    VoiceSettingsView()
                case .shortcutBar:
                    ShortcutBarView()
                case .pairedMacs:
                    PairedMacsListView()
                case .householdApplePushService:
                    HouseholdApplePushServiceView()
                }
            }
        }
        .preferredColorScheme(SoyehtTheme.preferredColorScheme)
        .onAppear {
            fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
            cursorStyleLabel = CursorStyleHelper.displayName(for: TerminalPreferences.shared.cursorStyle)
            hapticLabel = TerminalPreferences.shared.hapticEnabled
                ? String(localized: "settings.value.on")
                : String(localized: "settings.value.off")
            colorThemeLabel = TerminalColorTheme.active.displayName
            voiceLabel = TerminalPreferences.shared.voiceInputEnabled
                ? String(localized: "settings.value.on")
                : String(localized: "settings.value.off")
            shortcutBarLabel = TerminalPreferences.shared.shortcutBarLabel
            refreshHouseholdApplePushLabel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtShortcutBarChanged)) { _ in
            shortcutBarLabel = TerminalPreferences.shared.shortcutBarLabel
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtVoiceInputSettingsChanged)) { _ in
            voiceLabel = TerminalPreferences.shared.voiceInputEnabled
                ? String(localized: "settings.value.on")
                : String(localized: "settings.value.off")
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtColorThemeChanged)) { _ in
            colorThemeLabel = TerminalColorTheme.active.displayName
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtFontSizeChanged)) { _ in
            fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtCursorStyleChanged)) { _ in
            cursorStyleLabel = CursorStyleHelper.displayName(for: TerminalPreferences.shared.cursorStyle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtHapticSettingsChanged)) { _ in
            hapticLabel = TerminalPreferences.shared.hapticEnabled
                ? String(localized: "settings.value.on")
                : String(localized: "settings.value.off")
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtHouseholdApplePushPreferenceChanged)) { _ in
            refreshHouseholdApplePushLabel()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SoyehtTheme.bgTertiary)
            .frame(height: 1)
    }

    private func refreshHouseholdApplePushLabel() {
        activeHousehold = try? householdSessionStore.load()
        guard let activeHousehold else {
            householdApplePushEnabled = true
            householdApplePushLabel = String(localized: "settings.value.on")
            return
        }
        householdApplePushEnabled = HouseholdApplePushPreference.isEnabled(for: activeHousehold.householdId)
        householdApplePushLabel = householdApplePushEnabled
            ? String(localized: "settings.value.on")
            : String(localized: "settings.value.off")
    }
}
