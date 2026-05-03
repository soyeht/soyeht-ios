import SwiftUI
import SoyehtCore

// MARK: - Cursor Style Helper

enum CursorStyleHelper {
    static let options: [CursorStyleOption] = [
        CursorStyleOption(id: "blinkBlock", labelKey: "settings.cursorStyle.blinkBlock", preview: "\u{2588}"),
        CursorStyleOption(id: "steadyBlock", labelKey: "settings.cursorStyle.steadyBlock", preview: "\u{2588}"),
        CursorStyleOption(id: "blinkUnderline", labelKey: "settings.cursorStyle.blinkUnderline", preview: "_"),
        CursorStyleOption(id: "steadyUnderline", labelKey: "settings.cursorStyle.steadyUnderline", preview: "_"),
        CursorStyleOption(id: "blinkBar", labelKey: "settings.cursorStyle.blinkBar", preview: "|"),
        CursorStyleOption(id: "steadyBar", labelKey: "settings.cursorStyle.steadyBar", preview: "|"),
    ]

    static func displayName(for id: String) -> String {
        let key = options.first { $0.id == id }?.labelKey ?? "settings.cursorStyle.blinkBlock"
        return String(localized: String.LocalizationValue(key))
    }
}

struct CursorStyleOption: Identifiable {
    let id: String
    let labelKey: String
    let preview: String
}

// MARK: - Preset Colors

private struct PresetColor: Identifiable {
    let id: String
    let nameKey: String

    static let all: [PresetColor] = [
        PresetColor(id: "#10B981", nameKey: "settings.cursorStyle.preset.green"),
        PresetColor(id: "#3B82F6", nameKey: "settings.cursorStyle.preset.blue"),
        PresetColor(id: "#EF4444", nameKey: "settings.cursorStyle.preset.red"),
        PresetColor(id: "#F59E0B", nameKey: "settings.cursorStyle.preset.amber"),
        PresetColor(id: "#06B6D4", nameKey: "settings.cursorStyle.preset.cyan"),
        PresetColor(id: "#A855F7", nameKey: "settings.cursorStyle.preset.purple"),
        PresetColor(id: "#E5E7EB", nameKey: "settings.cursorStyle.preset.gray"),
        PresetColor(id: "#EC4899", nameKey: "settings.cursorStyle.preset.pink"),
    ]
}

// MARK: - Cursor Style View

struct CursorStyleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStyle: String = TerminalPreferences.shared.cursorStyle
    @State private var selectedColorHex: String = TerminalPreferences.shared.cursorColorHex

    var body: some View {
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

                    Text("settings.row.cursorStyle")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Cursor style section
                        Text("settings.cursorStyle.section.default")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("settings.cursorStyle.section.default.description")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        // Style list
                        VStack(spacing: 8) {
                            ForEach(CursorStyleHelper.options) { option in
                                Button {
                                    selectedStyle = option.id
                                    TerminalPreferences.shared.cursorStyle = option.id
                                    NotificationCenter.default.post(name: .soyehtCursorStyleChanged, object: nil)
                                } label: {
                                    cursorStyleRow(option: option, isSelected: selectedStyle == option.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Divider
                        Rectangle()
                            .fill(SoyehtTheme.bgTertiary)
                            .frame(height: 1)

                        // Cursor color section
                        Text("settings.cursorStyle.section.color")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("settings.cursorStyle.section.color.description")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        // Preset color swatches
                        HStack(spacing: 10) {
                            ForEach(PresetColor.all) { preset in
                                Button {
                                    selectedColorHex = preset.id
                                    TerminalPreferences.shared.cursorColorHex = preset.id
                                    NotificationCenter.default.post(name: .soyehtCursorColorChanged, object: nil)
                                } label: {
                                    colorSwatch(hex: preset.id, isSelected: selectedColorHex.caseInsensitiveCompare(preset.id) == .orderedSame)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        // Selected label
                        if let preset = PresetColor.all.first(where: { $0.id.caseInsensitiveCompare(selectedColorHex) == .orderedSame }) {
                            let presetName = String(localized: String.LocalizationValue(preset.nameKey))
                            Text(LocalizedStringResource(
                                "settings.cursorStyle.selected",
                                defaultValue: "Selected: \(presetName)",
                                comment: "Currently-selected color preset label. %@ = color name."
                            ))
                                .font(Typography.monoTagMedium)
                                .foregroundColor(Color(hex: preset.id))
                        } else {
                            Text("settings.cursorStyle.selected.custom")
                                .font(Typography.monoTagMedium)
                                .foregroundColor(Color(hex: selectedColorHex))
                        }

                        // Custom color row
                        NavigationLink(value: SettingsRoute.customColor) {
                            HStack(spacing: 12) {
                                Image(systemName: "paintpalette")
                                    .font(Typography.sansBody)
                                    .foregroundColor(SoyehtTheme.historyGray)
                                    .frame(width: 18, alignment: .center)

                                Text("settings.cursorStyle.custom.row")
                                    .font(Typography.monoCardBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(Typography.sansSmall)
                                    .foregroundColor(SoyehtTheme.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .overlay(
                                Rectangle()
                                    .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)

                        Text("settings.cursorStyle.common")
                            .font(Typography.monoSmall)
                            .foregroundColor(SoyehtTheme.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .soyehtCursorColorChanged)) { _ in
            selectedColorHex = TerminalPreferences.shared.cursorColorHex
        }
    }

    // MARK: - Cursor Style Row

    private func cursorStyleRow(option: CursorStyleOption, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            // Radio indicator
            Circle()
                .fill(isSelected ? SoyehtTheme.historyGreen : Color.clear)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(isSelected ? SoyehtTheme.historyGreen : SoyehtTheme.textTertiary, lineWidth: 1)
                )
                .shadow(color: isSelected ? SoyehtTheme.historyGreenStrong : .clear, radius: 6)

            Text(LocalizedStringKey(option.labelKey))
                .font(isSelected ? Typography.monoCardMedium : Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Text(option.preview)
                .font(Typography.monoSectionRegular)
                .foregroundColor(isSelected ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
        }
        .padding(16)
        .overlay(
            Rectangle()
                .stroke(isSelected ? SoyehtTheme.historyGreen : SoyehtTheme.bgTertiary, lineWidth: 1)
        )
    }

    // MARK: - Color Swatch

    private func colorSwatch(hex: String, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(hex: hex))
            .frame(width: 34, height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? SoyehtTheme.historyGreen : Color.clear, lineWidth: 2)
            )
            .shadow(color: isSelected ? Color(hex: hex) : .clear, radius: 8)
    }
}
