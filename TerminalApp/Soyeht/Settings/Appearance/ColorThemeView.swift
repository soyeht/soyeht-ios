import SwiftUI
import SoyehtCore

struct ColorThemeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTheme: String = ColorTheme.active.rawValue

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

                    Text("settings.row.colorTheme")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("settings.colorTheme.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("settings.colorTheme.description")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        // Theme cards
                        VStack(spacing: 8) {
                            ForEach(ColorTheme.allCases) { theme in
                                Button {
                                    selectedTheme = theme.rawValue
                                    TerminalPreferences.shared.colorTheme = theme.rawValue
                                    TerminalPreferences.shared.cursorColorHex = theme.defaultCursorHex
                                    NotificationCenter.default.post(name: .soyehtColorThemeChanged, object: nil)
                                    NotificationCenter.default.post(name: .soyehtCursorColorChanged, object: nil)
                                } label: {
                                    themeCard(theme: theme, isSelected: selectedTheme == theme.rawValue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Theme Card

    private func themeCard(theme: ColorTheme, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            // Radio dot
            Circle()
                .fill(isSelected ? SoyehtTheme.historyGreen : Color.clear)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle().stroke(
                        isSelected ? SoyehtTheme.historyGreen : Color(hex: "#4B5563"),
                        lineWidth: 1
                    )
                )
                .shadow(
                    color: isSelected ? SoyehtTheme.historyGreen.opacity(0.4) : .clear,
                    radius: isSelected ? 6 : 0
                )

            // Theme name
            Text(theme.displayName)  // LocalizedStringResource → auto-localized via SoyehtCore catalog
                .font(Typography.mono(size: 13 * Typography.uiScale, weight: isSelected ? .medium : .regular))
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            // 4 color preview swatches
            HStack(spacing: 4) {
                ForEach(Array(theme.previewSwatches.enumerated()), id: \.offset) { _, color in
                    Rectangle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                }
            }
        }
        .padding(12)
        .overlay(
            Rectangle().stroke(
                isSelected ? SoyehtTheme.historyGreen : Color(hex: "#1A1A1A"),
                lineWidth: 1
            )
        )
    }
}
