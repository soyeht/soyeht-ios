import SwiftUI
import SoyehtCore

struct HapticZoneView: View {
    private enum Metrics {
        static let rootStackSpacing: CGFloat = 0
        static let navSpacing: CGFloat = 12
        static let screenHorizontalPadding: CGFloat = 16
        static let navVerticalPadding: CGFloat = 12
        static let contentSpacing: CGFloat = 14
        static let contentTopPadding: CGFloat = 20
        static let masterToggleIconWidth: CGFloat = 20
        static let masterTogglePadding: CGFloat = 16
        static let zoneCardSpacing: CGFloat = 10
        static let zoneHeaderSpacing: CGFloat = 8
        static let zoneIconColumnWidth: CGFloat = 18
        static let dividerHeight: CGFloat = 1
        static let borderLineWidth: CGFloat = 1
        static let zoneCardPadding: CGFloat = 14
        static let radioRowSpacing: CGFloat = 10
        static let radioIndicatorSize: CGFloat = 12
        static let radioRowPadding: CGFloat = 4
        static let keyTagSpacing: CGFloat = 6
        static let keyTagVerticalPadding: CGFloat = 4
        static let keyTagHorizontalPadding: CGFloat = 8
        static let quickReferenceSpacing: CGFloat = 6
        static let quickReferenceVerticalPadding: CGFloat = 10
        static let quickReferenceHorizontalPadding: CGFloat = 12
        static let zoneExpandAnimationDuration: TimeInterval = 0.2
    }

    @Environment(\.dismiss) private var dismiss
    @State private var hapticEnabled: Bool = TerminalPreferences.shared.hapticEnabled
    @State private var expandedZone: HapticZone? = nil
    @State private var zoneSelections: [HapticZone: HapticType] = {
        var dict: [HapticZone: HapticType] = [:]
        for zone in HapticZone.allCases {
            dict[zone] = TerminalPreferences.shared.hapticType(for: zone)
        }
        return dict
    }()

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Metrics.rootStackSpacing) {
                // Nav bar
                HStack(spacing: Metrics.navSpacing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }

                    Text("settings.row.hapticFeedback")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, Metrics.screenHorizontalPadding)
                .padding(.vertical, Metrics.navVerticalPadding)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.contentSpacing) {
                        Text("settings.haptic.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("settings.haptic.description")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        // Master toggle
                        masterToggle

                        // Zone groups
                        ForEach(HapticZone.allCases) { zone in
                            zoneGroup(zone)
                        }
                        .disabled(!hapticEnabled)

                        // Quick reference
                        quickReference
                    }
                    .padding(.horizontal, Metrics.screenHorizontalPadding)
                    .padding(.top, Metrics.contentTopPadding)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Master Toggle

    private var masterToggle: some View {
        HStack(spacing: Metrics.navSpacing) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(Typography.sansSection)
                .foregroundColor(hapticEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                .frame(width: Metrics.masterToggleIconWidth, alignment: .center)

            Text("settings.row.hapticFeedback")
                .font(Typography.monoCardMedium)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Toggle("", isOn: $hapticEnabled)
                .labelsHidden()
                .tint(SoyehtTheme.historyGreen)
                .onChange(of: hapticEnabled) { newValue in
                    TerminalPreferences.shared.hapticEnabled = newValue
                    NotificationCenter.default.post(name: .soyehtHapticSettingsChanged, object: nil)
                }
        }
        .padding(Metrics.masterTogglePadding)
        .background(SoyehtTheme.bgPrimary)
        .overlay(
            Rectangle()
                .stroke(SoyehtTheme.bgTertiary, lineWidth: Metrics.borderLineWidth)
        )
    }

    // MARK: - Zone Group

    private func zoneGroup(_ zone: HapticZone) -> some View {
        let isExpanded = expandedZone == zone
        let selectedType = zoneSelections[zone] ?? zone.defaultType

        return VStack(alignment: .leading, spacing: Metrics.zoneCardSpacing) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: Metrics.zoneExpandAnimationDuration)) {
                    expandedZone = isExpanded ? nil : zone
                }
            } label: {
                HStack(spacing: Metrics.zoneHeaderSpacing) {
                    Image(systemName: zone.icon)
                        .font(Typography.sansBody)
                        .foregroundColor(zoneIconColor(zone))
                        .frame(width: Metrics.zoneIconColumnWidth, alignment: .center)

                    Text(zone.displayName)
                        .font(Typography.monoCardMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()

                    Text(selectedType.displayName)
                        .font(Typography.monoSmall)
                        .foregroundColor(isExpanded ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(Typography.sansSmall)
                        .foregroundColor(isExpanded ? SoyehtTheme.historyGreen : SoyehtTheme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            // Key tags
            HStack(spacing: Metrics.keyTagSpacing) {
                ForEach(zone.keyLabels, id: \.self) { label in
                    keyTag(label, zone: zone)
                }
            }

            // Expanded content
            if isExpanded {
                Rectangle()
                    .fill(SoyehtTheme.bgTertiary)
                    .frame(height: Metrics.dividerHeight)

                ForEach(HapticType.groupedOptions, id: \.category) { group in
                    if let header = group.category.header {
                        Text(header)
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }

                    if group.category == .none {
                        Rectangle()
                            .fill(SoyehtTheme.bgTertiary)
                            .frame(height: Metrics.dividerHeight)
                    }

                    ForEach(group.types, id: \.self) { type in
                        radioRow(type: type, isSelected: selectedType == type, zone: zone)
                    }
                }
            }
        }
        .padding(Metrics.zoneCardPadding)
        .background(SoyehtTheme.bgPrimary)
        .overlay(
            Rectangle()
                .stroke(
                    isExpanded ? SoyehtTheme.historyGreen : SoyehtTheme.bgCardBorder,
                    lineWidth: Metrics.borderLineWidth
                )
        )
    }

    // MARK: - Radio Row

    private func radioRow(type: HapticType, isSelected: Bool, zone: HapticZone) -> some View {
        Button {
            zoneSelections[zone] = type
            TerminalPreferences.shared.setHapticType(type, for: zone)
            NotificationCenter.default.post(name: .soyehtHapticSettingsChanged, object: nil)
            if type != .disabled {
                HapticEngine.shared.play(zone: zone)
            }
        } label: {
            HStack(spacing: Metrics.radioRowSpacing) {
                // Radio indicator
                if isSelected {
                    Circle()
                        .fill(SoyehtTheme.historyGreen)
                        .frame(width: Metrics.radioIndicatorSize, height: Metrics.radioIndicatorSize)
                } else {
                    Circle()
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: Metrics.borderLineWidth)
                        .frame(width: Metrics.radioIndicatorSize, height: Metrics.radioIndicatorSize)
                }

                Text(type.displayName)
                    .font(isSelected ? Typography.monoLabel : Typography.monoLabelRegular)
                    .foregroundColor(isSelected ? SoyehtTheme.historyGreen : SoyehtTheme.textSecondary)

                if isSelected && type != .disabled {
                    Spacer()

                    Text("settings.haptic.radio.active")
                        .font(Typography.monoMicroMedium)
                        .foregroundColor(SoyehtTheme.historyGreen)
                }
            }
            .padding(.vertical, Metrics.radioRowPadding)
            .padding(.horizontal, Metrics.radioRowPadding)
            .background(isSelected ? SoyehtTheme.selection : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Key Tag

    private func keyTag(_ label: String, zone: HapticZone) -> some View {
        let (textColor, bgColor) = keyTagStyle(label: label, zone: zone)
        return Text(label)
            .font(Typography.monoSmallMedium)
            .foregroundColor(textColor)
            .padding(.vertical, Metrics.keyTagVerticalPadding)
            .padding(.horizontal, Metrics.keyTagHorizontalPadding)
            .background(bgColor)
    }

    private func keyTagStyle(label: String, zone: HapticZone) -> (Color, Color) {
        switch zone {
        case .clicky:
            if label == "Kill" {
                return (SoyehtTheme.accentRed, SoyehtTheme.bgCard)
            }
            return (SoyehtTheme.historyGreen, SoyehtTheme.historyGreenBg)
        default:
            return (SoyehtTheme.textPrimary, SoyehtTheme.bgTertiary)
        }
    }

    private func zoneIconColor(_ zone: HapticZone) -> Color {
        switch zone {
        case .alphanumeric: return SoyehtTheme.textTertiary
        case .clicky: return SoyehtTheme.accentLink
        case .tactile: return SoyehtTheme.accentAlternate
        case .gestures: return SoyehtTheme.accentAmber
        case .voice: return SoyehtTheme.accentInfo
        }
    }

    // MARK: - Quick Reference

    private var quickReference: some View {
        VStack(alignment: .leading, spacing: Metrics.quickReferenceSpacing) {
            Text("settings.haptic.quickRef.section")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.historyGray)

            Text("settings.haptic.quickRef.impact")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textPrimary)

            Text("settings.haptic.quickRef.selection")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textPrimary)

            Text("settings.haptic.quickRef.notif")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textPrimary)
        }
        .padding(.vertical, Metrics.quickReferenceVerticalPadding)
        .padding(.horizontal, Metrics.quickReferenceHorizontalPadding)
        .background(SoyehtTheme.bgPrimary)
        .overlay(
            Rectangle()
                .stroke(SoyehtTheme.bgCardBorder, lineWidth: Metrics.borderLineWidth)
        )
    }
}
