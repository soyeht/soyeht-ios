import SwiftUI

struct SettingsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)

    var body: some View {
        NavigationStack(path: $path) {
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
                            Text("// terminal settings")
                                .font(SoyehtTheme.labelFont)
                                .foregroundColor(SoyehtTheme.historyGray)

                            Text("Customize the appearance and behavior of the terminal.")
                                .font(SoyehtTheme.tagFont)
                                .foregroundColor(SoyehtTheme.textTertiary)

                            Spacer().frame(height: 4)

                            // Settings list
                            VStack(spacing: 0) {
                                Button { path.append(SettingsRoute.fontSize) } label: {
                                    SettingsRow(icon: "textformat.size", label: "Font Size", value: fontSizeLabel)
                                }
                                .buttonStyle(.plain)

                                divider

                                SettingsRow(icon: "paintpalette", label: "Color Theme", value: "Soyeht Dark")
                                divider
                                SettingsRow(icon: "character.cursor.ibeam", label: "Cursor Style", value: "Block")
                                divider
                                SettingsRow(icon: "keyboard", label: "Shortcut Bar", value: "Default")
                                divider
                                SettingsRow(icon: "iphone.radiowaves.left.and.right", label: "Haptic Feedback", value: "On", valueColor: SoyehtTheme.historyGreen)
                                divider
                                SettingsRow(icon: "bell", label: "Terminal Sound", value: "Sound")
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
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .soyehtFontSizeChanged)) { _ in
            fontSizeLabel = String(format: "%.0fpt", TerminalPreferences.shared.fontSize)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SoyehtTheme.bgTertiary)
            .frame(height: 1)
    }
}
