import SwiftUI
import SoyehtCore

struct FontSizeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fontSize: CGFloat = TerminalPreferences.shared.fontSize

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

                    Text("settings.row.fontSize")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("settings.fontSize.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("settings.fontSize.description")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        // Large value display
                        Text(String(format: "%.0fpt", fontSize))
                            .font(Typography.monoDisplay)
                            .foregroundColor(SoyehtTheme.historyGreen)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)

                        // Slider
                        Slider(value: $fontSize, in: 8...24, step: 1)
                            .tint(SoyehtTheme.historyGreen)
                            .accessibilityIdentifier(AccessibilityID.Settings.fontSizeSlider)

                        // Range labels
                        HStack {
                            Text("8pt")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.historyGray)
                            Spacer()
                            Text("24pt")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.historyGray)
                        }

                        Spacer().frame(height: 12)

                        // Preview
                        Text("settings.fontSize.preview.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        TerminalPreview(fontSize: fontSize)
                            .frame(height: 150)
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
        .onChange(of: fontSize) { newValue in
            TerminalPreferences.shared.fontSize = newValue
            NotificationCenter.default.post(name: .soyehtFontSizeChanged, object: nil)
        }
    }
}
