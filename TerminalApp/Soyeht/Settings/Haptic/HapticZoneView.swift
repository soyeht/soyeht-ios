import SwiftUI
import SoyehtCore

struct HapticZoneView: View {
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
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Nav bar
                HStack(spacing: 12) {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
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
                        .opacity(hapticEnabled ? 1.0 : 0.4)
                        .disabled(!hapticEnabled)

                        // Quick reference
                        quickReference
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Master Toggle

    private var masterToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(Typography.sansSection)
                .foregroundColor(hapticEnabled ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                .frame(width: 20, alignment: .center)

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
        .padding(16)
        .background(Color.black)
        .overlay(
            Rectangle()
                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
        )
    }

    // MARK: - Zone Group

    private func zoneGroup(_ zone: HapticZone) -> some View {
        let isExpanded = expandedZone == zone
        let selectedType = zoneSelections[zone] ?? zone.defaultType

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedZone = isExpanded ? nil : zone
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: zone.icon)
                        .font(Typography.sansBody)
                        .foregroundColor(Color(hex: zone.iconColorHex))
                        .frame(width: 18, alignment: .center)

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
            HStack(spacing: 6) {
                ForEach(zone.keyLabels, id: \.self) { label in
                    keyTag(label, zone: zone)
                }
            }

            // Expanded content
            if isExpanded {
                Rectangle()
                    .fill(Color(hex: "#1A1A1A"))
                    .frame(height: 1)

                ForEach(HapticType.groupedOptions, id: \.category) { group in
                    if let header = group.category.header {
                        Text(header)
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.historyGray)
                    }

                    if group.category == .none {
                        Rectangle()
                            .fill(Color(hex: "#1A1A1A"))
                            .frame(height: 1)
                    }

                    ForEach(group.types, id: \.self) { type in
                        radioRow(type: type, isSelected: selectedType == type, zone: zone)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            Rectangle()
                .stroke(
                    isExpanded ? SoyehtTheme.historyGreen : Color(hex: "#2A2A2A"),
                    lineWidth: 1
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
            HStack(spacing: 10) {
                // Radio indicator
                if isSelected {
                    Circle()
                        .fill(SoyehtTheme.historyGreen)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .stroke(Color(hex: "#3A3A3A"), lineWidth: 1)
                        .frame(width: 12, height: 12)
                }

                Text(type.displayName)
                    .font(isSelected ? Typography.monoLabel : Typography.monoLabelRegular)
                    .foregroundColor(isSelected ? SoyehtTheme.historyGreen : Color(hex: "#9CA3AF"))

                if isSelected && type != .disabled {
                    Spacer()

                    Text("settings.haptic.radio.active")
                        .font(Typography.monoMicroMedium)
                        .foregroundColor(SoyehtTheme.historyGreen)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isSelected ? Color(hex: "#10B981").opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Key Tag

    private func keyTag(_ label: String, zone: HapticZone) -> some View {
        let (textColor, bgColor) = keyTagStyle(label: label, zone: zone)
        return Text(label)
            .font(Typography.monoSmallMedium)
            .foregroundColor(textColor)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(bgColor)
    }

    private func keyTagStyle(label: String, zone: HapticZone) -> (Color, Color) {
        switch zone {
        case .clicky:
            if label == "Kill" {
                return (SoyehtTheme.accentRed, Color(hex: "#2A1A1A"))
            }
            return (SoyehtTheme.historyGreen, Color(hex: "#1A2A1A"))
        default:
            return (SoyehtTheme.textPrimary, Color(hex: "#1A1A1A"))
        }
    }

    // MARK: - Quick Reference

    private var quickReference: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            Rectangle()
                .stroke(Color(hex: "#2A2A2A"), lineWidth: 1)
        )
    }
}
