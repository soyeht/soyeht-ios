import SwiftUI
import SoyehtCore

// MARK: - Cursor Style Helper

enum CursorStyleHelper {
    static let options: [CursorStyleOption] = [
        CursorStyleOption(id: "blinkBlock", label: "Blinking Block", preview: "\u{2588}"),
        CursorStyleOption(id: "steadyBlock", label: "Steady Block", preview: "\u{2588}"),
        CursorStyleOption(id: "blinkUnderline", label: "Blinking Underline", preview: "_"),
        CursorStyleOption(id: "steadyUnderline", label: "Steady Underline", preview: "_"),
        CursorStyleOption(id: "blinkBar", label: "Blinking Bar", preview: "|"),
        CursorStyleOption(id: "steadyBar", label: "Steady Bar", preview: "|"),
    ]

    static func displayName(for id: String) -> String {
        options.first { $0.id == id }?.label ?? "Blinking Block"
    }
}

struct CursorStyleOption: Identifiable {
    let id: String
    let label: String
    let preview: String
}

// MARK: - Preset Colors

private struct PresetColor: Identifiable {
    let id: String
    let name: String

    static let all: [PresetColor] = [
        PresetColor(id: "#10B981", name: "Green"),
        PresetColor(id: "#3B82F6", name: "Blue"),
        PresetColor(id: "#EF4444", name: "Red"),
        PresetColor(id: "#F59E0B", name: "Amber"),
        PresetColor(id: "#06B6D4", name: "Cyan"),
        PresetColor(id: "#A855F7", name: "Purple"),
        PresetColor(id: "#E5E7EB", name: "Gray"),
        PresetColor(id: "#EC4899", name: "Pink"),
    ]
}

// MARK: - Cursor Style View

struct CursorStyleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStyle: String = TerminalPreferences.shared.cursorStyle
    @State private var selectedColorHex: String = TerminalPreferences.shared.cursorColorHex

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

                    Text("Cursor Style")
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
                        Text("// default cursor style")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("SwiftTerm supports 6 cursor styles. Choose the default.")
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
                        Text("// cursor color")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("Choose the cursor color. The color will be applied to the style chosen above.")
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
                            Text("Selected: \(preset.name)")
                                .font(Typography.monoTagMedium)
                                .foregroundColor(Color(hex: preset.id))
                        } else {
                            Text("Selected: Custom")
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

                                Text("Custom color...")
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

                        Text("Common in terminal apps.")
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
                .shadow(color: isSelected ? SoyehtTheme.historyGreen.opacity(0.4) : .clear, radius: 6)

            Text(option.label)
                .font(Typography.mono(size: 13 * Typography.uiScale, weight: isSelected ? .medium : .regular))
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
            .shadow(color: isSelected ? Color(hex: hex).opacity(0.4) : .clear, radius: 8)
    }
}
