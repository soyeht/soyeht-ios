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
    @State private var householdApplePushEnabled = true
    @State private var householdApplePushLabel = String(localized: "settings.value.on")
    @State private var mobileClawVPNConfig = MobileClawVPNRendezvousControlPlaneLaunchConfig.current()
    @State private var showLeaveHouseholdConfirmation = false

    @ObservedObject private var identity = SoyehtIdentity.shared
    @ObservedObject private var serverRegistry = ServerRegistry.shared

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
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "common.accessibility.back",
                            defaultValue: "Back",
                            comment: "VoiceOver label for the back chevron in custom navigation headers."
                        )))

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
                                        value: "\(serverRegistry.macs.count)"
                                    )
                                }
                                .buttonStyle(.plain)
                                if SoyehtFeatureFlags.mobileClawVPNControlPlaneEnabled {
                                    divider
                                    Button { path.append(SettingsRoute.mobileClawVPNControlPlane) } label: {
                                        SettingsRow(
                                            icon: "shield.lefthalf.filled",
                                            label: "Mobile Claw VPN",
                                            value: mobileClawVPNConfig.isConfigured ? "DEV" : "Config",
                                            valueColor: mobileClawVPNConfig.isConfigured ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(AccessibilityID.Settings.mobileClawVPNButton)
                                }
                                if identity.isActive {
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
                                    divider
                                    Button { showLeaveHouseholdConfirmation = true } label: {
                                        SettingsRow(
                                            icon: "rectangle.portrait.and.arrow.right",
                                            label: "settings.row.leaveHousehold",
                                            value: ""
                                        )
                                    }
                                    .buttonStyle(.plain)
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
            .alert(
                Text(LocalizedStringResource(
                    "settings.leaveHousehold.confirm.title",
                    defaultValue: "Leave this household?",
                    comment: "Confirmation alert title before destroying local household membership."
                )),
                isPresented: $showLeaveHouseholdConfirmation
            ) {
                Button(role: .destructive) {
                    leaveHousehold()
                } label: {
                    Text(LocalizedStringResource(
                        "settings.leaveHousehold.confirm.action",
                        defaultValue: "Leave",
                        comment: "Destructive confirm button for leaving a household."
                    ))
                }
                Button(role: .cancel) {} label: {
                    Text(LocalizedStringResource(
                        "common.cancel",
                        defaultValue: "Cancel",
                        comment: "Generic cancel button label."
                    ))
                }
            } message: {
                Text(LocalizedStringResource(
                    "settings.leaveHousehold.confirm.body",
                    defaultValue: "Soyeht will wipe its local membership on this iPhone and restart with the welcome screen. The household and its other devices are not affected — re-pair from a host machine to rejoin.",
                    comment: "Explanation shown in the leave-household confirmation alert."
                ))
            }
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
                case .mobileClawVPNControlPlane:
                    MobileClawVPNRendezvousControlPlaneView()
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
            mobileClawVPNConfig = .current()
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

    /// Wipes local household membership and bounces the app back to the
    /// fresh welcome carousel. Reuses the existing debug reset URL which
    /// `AppDelegate` already handles for development tooling — calling it
    /// from Settings exposes the same reset path as a first-class exit so
    /// the user always has a way OUT of the household home view rather
    /// than being stuck on a screen that has no logical "back".
    private func leaveHousehold() {
        guard let url = URL(string: "soyeht://debug/reset-local-state") else { return }
        // Arm the reset handler so the upcoming URL delivery is recognized
        // as originating from this user-confirmed Settings flow. External
        // callers (other apps, Shortcuts, AirDrop'd .url) hit the URL
        // handler without the flag and are refused — preventing silent
        // membership/keychain wipes.
        DebugLocalStateResetter.armedFromSettings = true
        UIApplication.shared.open(url)
    }

    private func refreshHouseholdApplePushLabel() {
        // Pull the latest state directly so a label refresh after an
        // out-of-band write (e.g. pair-device just saved a new
        // household) does not lag a `@Published` propagation tick.
        identity.reload()
        guard let snapshot = identity.active else {
            householdApplePushEnabled = true
            householdApplePushLabel = String(localized: "settings.value.on")
            return
        }
        householdApplePushEnabled = HouseholdApplePushPreference.isEnabled(for: snapshot.id)
        householdApplePushLabel = householdApplePushEnabled
            ? String(localized: "settings.value.on")
            : String(localized: "settings.value.off")
    }
}

struct MobileClawVPNRendezvousControlPlaneView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MobileClawVPNRendezvousViewModel
    private let config: MobileClawVPNRendezvousControlPlaneLaunchConfig

    @MainActor
    init(
        model: MobileClawVPNRendezvousViewModel? = nil,
        config: MobileClawVPNRendezvousControlPlaneLaunchConfig = .current()
    ) {
        self._model = StateObject(wrappedValue: model ?? MobileClawVPNRendezvousViewModel())
        self.config = config
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

                    Text("Mobile Claw VPN")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("DEV control-plane")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: config.isConfigured ? "checkmark.shield" : "exclamationmark.shield")
                                    .font(Typography.sansCard)
                                    .foregroundColor(config.isConfigured ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)

                                Text("Launch config")
                                    .font(Typography.monoCardBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Spacer()

                                Text(config.isConfigured ? "Configured" : "Missing")
                                    .font(Typography.monoTag)
                                    .foregroundColor(config.isConfigured ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                                    .accessibilityIdentifier(AccessibilityID.Settings.mobileClawVPNConfigState)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)

                            divider

                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(Typography.sansCard)
                                    .foregroundColor(statusColor)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)

                                Text("Rendezvous")
                                    .font(Typography.monoCardBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Spacer()

                                Text(statusText)
                                    .font(Typography.monoTag)
                                    .foregroundColor(statusColor)
                                    .accessibilityIdentifier(AccessibilityID.Settings.mobileClawVPNStatusLabel)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .overlay(
                            Rectangle()
                                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                        )

                        Button(action: startAuthorization) {
                            HStack(spacing: 10) {
                                Image(systemName: model.phase == .authorizing ? "hourglass" : "bolt.shield")
                                    .font(Typography.sansBody)
                                Text(authorizeButtonTitle)
                                    .font(Typography.monoCardBody)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(canAuthorize ? SoyehtTheme.bgPrimary : SoyehtTheme.historyGray)
                            .background(canAuthorize ? SoyehtTheme.historyGreen : SoyehtTheme.bgTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAuthorize)
                        .accessibilityIdentifier(AccessibilityID.Settings.mobileClawVPNAuthorizeButton)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private var canAuthorize: Bool {
        config.isConfigured && model.phase != .authorizing
    }

    private var authorizeButtonTitle: String {
        switch model.phase {
        case .authorizing:
            "Authorizing"
        case .authorized:
            "Authorize again"
        case .failed:
            "Retry authorize"
        case .idle:
            "Authorize rendezvous"
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle:
            config.isConfigured ? "Ready" : "Missing config"
        case .authorizing:
            "Authorizing"
        case .authorized:
            "Control-plane authorized"
        case .failed:
            "Failed"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .authorized:
            SoyehtTheme.historyGreen
        case .failed:
            SoyehtTheme.accentRed
        case .authorizing:
            SoyehtTheme.historyGray
        case .idle:
            config.isConfigured ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SoyehtTheme.bgTertiary)
            .frame(height: 1)
    }

    private func startAuthorization() {
        guard let deviceId = config.deviceId, let clawId = config.clawId else { return }
        Task {
            await model.authorize(deviceId: deviceId, clawId: clawId)
        }
    }
}

struct MobileClawVPNRendezvousControlPlaneLaunchConfig: Equatable {
    static let deviceIDArgument = "-SoyehtMobileClawVPNDeviceID"
    static let clawIDArgument = "-SoyehtMobileClawVPNClawID"

    let deviceId: String?
    let clawId: String?

    var isConfigured: Bool {
        deviceId != nil && clawId != nil
    }

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        Self(
            deviceId: value(after: deviceIDArgument, in: arguments),
            clawId: value(after: clawIDArgument, in: arguments)
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        return value
    }
}
