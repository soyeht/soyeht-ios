import SwiftUI
import SoyehtCore

struct SettingsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
    @State private var cursorStyleLabel = CursorStyleHelper.displayName(for: TerminalPreferences.shared.cursorStyle)
    @State private var hapticLabel = TerminalPreferences.shared.hapticEnabled ? "On" : "Off"
    @State private var colorThemeLabel: String = String(localized: ColorTheme.active.displayName)
    @State private var voiceLabel = TerminalPreferences.shared.voiceInputEnabled ? "On" : "Off"
    @State private var shortcutBarLabel = TerminalPreferences.shared.shortcutBarLabel

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()

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
                                    SettingsRow(icon: "paintpalette", label: "Color Theme", value: colorThemeLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.colorThemeButton)
                                divider
                                Button { path.append(SettingsRoute.fontSize) } label: {
                                    SettingsRow(icon: "textformat.size", label: "Font Size", value: fontSizeLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.fontSizeButton)
                                divider
                                Button { path.append(SettingsRoute.cursorStyle) } label: {
                                    SettingsRow(icon: "character.cursor.ibeam", label: "Cursor Style", value: cursorStyleLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.cursorStyleButton)
                                divider
                                Button { path.append(SettingsRoute.shortcutBar) } label: {
                                    SettingsRow(icon: "keyboard", label: "Shortcut Bar", value: shortcutBarLabel)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.Settings.shortcutBarButton)
                                divider
                                Button { path.append(SettingsRoute.hapticFeedback) } label: {
                                    SettingsRow(
                                        icon: "iphone.radiowaves.left.and.right",
                                        label: "Haptic Feedback",
                                        value: hapticLabel,
                                        valueColor: hapticLabel == "On" ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
                                    )
                                }
                                .buttonStyle(.plain)
                                divider
                                Button { path.append(SettingsRoute.voiceInput) } label: {
                                    SettingsRow(
                                        icon: "mic",
                                        label: "Voice Input",
                                        value: voiceLabel,
                                        valueColor: voiceLabel == "On" ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
                                    )
                                }
                                .buttonStyle(.plain)
                                divider
                                Button { path.append(SettingsRoute.pairedMacs) } label: {
                                    SettingsRow(
                                        icon: "desktopcomputer",
                                        label: "Macs pareados",
                                        value: "\(PairedMacsStore.shared.macs.count)"
                                    )
                                }
                                .buttonStyle(.plain)
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
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
            cursorStyleLabel = CursorStyleHelper.displayName(for: TerminalPreferences.shared.cursorStyle)
            hapticLabel = TerminalPreferences.shared.hapticEnabled ? "On" : "Off"
            colorThemeLabel = String(localized: ColorTheme.active.displayName)
            voiceLabel = TerminalPreferences.shared.voiceInputEnabled ? "On" : "Off"
            shortcutBarLabel = TerminalPreferences.shared.shortcutBarLabel
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtShortcutBarChanged)) { _ in
            shortcutBarLabel = TerminalPreferences.shared.shortcutBarLabel
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtVoiceInputSettingsChanged)) { _ in
            voiceLabel = TerminalPreferences.shared.voiceInputEnabled ? "On" : "Off"
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtColorThemeChanged)) { _ in
            colorThemeLabel = String(localized: ColorTheme.active.displayName)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtFontSizeChanged)) { _ in
            fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtCursorStyleChanged)) { _ in
            cursorStyleLabel = CursorStyleHelper.displayName(for: TerminalPreferences.shared.cursorStyle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtHapticSettingsChanged)) { _ in
            hapticLabel = TerminalPreferences.shared.hapticEnabled ? "On" : "Off"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SoyehtTheme.bgTertiary)
            .frame(height: 1)
    }
}
