import SwiftUI
import SoyehtCore

struct VoiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var voiceEnabled = TerminalPreferences.shared.voiceInputEnabled
    @State private var selectedLanguage = TerminalPreferences.shared.voiceLanguage

    private let languages: [(id: String, nameKey: LocalizedStringKey)] = [
        ("auto", "settings.voice.language.auto"),
        ("en-US", "settings.voice.language.en-US"),
        ("en-GB", "settings.voice.language.en-GB"),
        ("pt-BR", "settings.voice.language.pt-BR"),
        ("pt-PT", "settings.voice.language.pt-PT"),
        ("es-ES", "settings.voice.language.es-ES"),
        ("es-MX", "settings.voice.language.es-MX"),
        ("fr-FR", "settings.voice.language.fr-FR"),
        ("de-DE", "settings.voice.language.de-DE"),
        ("ja-JP", "settings.voice.language.ja-JP"),
        ("zh-CN", "settings.voice.language.zh-CN"),
    ]

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
                    Text("settings.row.voiceInput")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("settings.voice.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        Text("settings.voice.description")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textTertiary)

                        Spacer().frame(height: 4)

                        // Enable toggle
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "mic.fill")
                                    .font(Typography.sansCard)
                                    .foregroundColor(Color(hex: "#06B6D4"))
                                    .frame(width: 20)

                                Text("settings.row.voiceInput")
                                    .font(Typography.monoCardBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)

                                Spacer()

                                Toggle("", isOn: $voiceEnabled)
                                    .labelsHidden()
                                    .tint(SoyehtTheme.historyGreen)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .overlay(
                            Rectangle()
                                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                        )

                        // Language picker
                        VStack(spacing: 0) {
                            ForEach(Array(languages.enumerated()), id: \.element.id) { index, lang in
                                if index > 0 {
                                    Rectangle()
                                        .fill(SoyehtTheme.bgTertiary)
                                        .frame(height: 1)
                                }
                                Button {
                                    selectedLanguage = lang.id
                                    TerminalPreferences.shared.voiceLanguage = lang.id
                                } label: {
                                    HStack {
                                        Text(lang.nameKey)
                                            .font(Typography.monoLabelRegular)
                                            .foregroundColor(SoyehtTheme.textPrimary)
                                        Spacer()
                                        if selectedLanguage == lang.id {
                                            Image(systemName: "checkmark")
                                                .font(Typography.sansSmall)
                                                .foregroundColor(SoyehtTheme.historyGreen)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .overlay(
                            Rectangle()
                                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                        )
                        .opacity(voiceEnabled ? 1.0 : 0.4)

                        // Info
                        Text("settings.voice.info")
                            .font(Typography.monoSmall)
                            .foregroundColor(SoyehtTheme.textTertiary)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
        .onChange(of: voiceEnabled) { newValue in
            TerminalPreferences.shared.voiceInputEnabled = newValue
            NotificationCenter.default.post(name: .soyehtVoiceInputSettingsChanged, object: nil)
        }
    }
}
