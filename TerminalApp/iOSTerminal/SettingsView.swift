import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private let settings: [SettingItem] = [
        SettingItem(icon: "textformat.size", label: "Font Size", value: "13pt"),
        SettingItem(icon: "paintpalette", label: "Color Theme", value: "Soyeht Dark"),
        SettingItem(icon: "character.cursor.ibeam", label: "Cursor Style", value: "Block"),
        SettingItem(icon: "keyboard", label: "Shortcut Bar", value: "Default"),
        SettingItem(icon: "iphone.radiowaves.left.and.right", label: "Haptic Feedback", value: "On", valueColor: SoyehtTheme.historyGreen),
        SettingItem(icon: "bell", label: "Terminal Sound", value: "Sound"),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Nav bar
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(SoyehtTheme.historyGray)
                    }

                    Text("Settings")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Comment
                        Text("// terminal settings")
                            .font(SoyehtTheme.labelFont)
                            .foregroundColor(SoyehtTheme.historyGray)

                        // Description
                        Text("Customize the appearance and behavior of the terminal.")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        // Spacer matching design
                        Spacer().frame(height: 4)

                        // Settings list
                        VStack(spacing: 0) {
                            ForEach(Array(settings.enumerated()), id: \.element.id) { index, item in
                                SettingsRow(item: item)

                                if index < settings.count - 1 {
                                    Rectangle()
                                        .fill(SoyehtTheme.bgTertiary)
                                        .frame(height: 1)
                                }
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
        .preferredColorScheme(.dark)
    }
}

// MARK: - Setting Item Model

private struct SettingItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = SoyehtTheme.historyGray
}

// MARK: - Settings Row

private struct SettingsRow: View {
    let item: SettingItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 14))
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(width: 18, alignment: .center)

            Text(item.label)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Text(item.value)
                .font(SoyehtTheme.tagFont)
                .foregroundColor(item.valueColor)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SoyehtTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
