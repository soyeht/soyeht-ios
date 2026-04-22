import SwiftUI
import SoyehtCore

struct CustomShortcutCreatorView: View {
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case keyCombo = "Key Combo"
        case textCommand = "Text Command"

        var titleKey: LocalizedStringKey {
            switch self {
            case .keyCombo: return "settings.shortcut.creator.mode.keyCombo"
            case .textCommand: return "settings.shortcut.creator.mode.textCommand"
            }
        }
    }

    @State private var mode: Mode = .keyCombo

    // Key combo state
    @State private var selectedModifier: ShortcutBarModifier = .ctrl
    @State private var selectedKey: Character? = nil

    // Text command state
    @State private var commandText = ""

    // Shared state
    @State private var label = ""
    @State private var descriptionText = ""

    var onSave: (ShortcutBarItem) -> Void

    private var isValid: Bool {
        switch mode {
        case .keyCombo: return selectedKey != nil
        case .textCommand: return !commandText.isEmpty
        }
    }

    private var autoLabel: String {
        switch mode {
        case .keyCombo:
            guard let key = selectedKey else { return "" }
            let lowered = key.lowercased()
            return selectedModifier == .ctrl ? "C-\(lowered)" : "M-\(lowered)"
        case .textCommand:
            if commandText.isEmpty { return "" }
            return commandText.count <= 8 ? commandText : String(commandText.prefix(7)) + "…"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        modeSelector
                        previewBox
                        Spacer().frame(height: 4)

                        if mode == .keyCombo {
                            modifierSection
                            Spacer().frame(height: 4)
                            keyGridSection
                        } else {
                            commandSection
                        }

                        Spacer().frame(height: 4)
                        labelSection
                        Spacer().frame(height: 4)
                        descriptionSection
                        Spacer().frame(height: 4)
                        hintsBox
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack {
            Button("common.button.cancel") { dismiss() }
                .font(Typography.monoLabelRegular)
                .foregroundColor(SoyehtTheme.historyGray)

            Spacer()

            Text("settings.shortcut.creator.title")
                .font(Typography.monoBodyMedium)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Button("common.button.save") { saveShortcut() }
                .font(Typography.monoLabel)
                .foregroundColor(isValid ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                .disabled(!isValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "#0A0A0A"))
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Text(m.titleKey)
                    .font(Typography.mono(size: 12 * Typography.uiScale, weight: mode == m ? .medium : .regular))
                    .foregroundColor(mode == m ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(mode == m ? Color(hex: "#10B981").opacity(0.12) : Color(hex: "#0A0A0A"))
                    .overlay(
                        Rectangle()
                            .stroke(mode == m ? SoyehtTheme.historyGreen : Color(hex: "#1A1A1A"), lineWidth: 1)
                    )
                    .onTapGesture { mode = m }
            }
        }
    }

    // MARK: - Preview Box

    private var previewBox: some View {
        VStack(spacing: 8) {
            Text("settings.shortcut.creator.preview.section")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                if mode == .keyCombo {
                    if let key = selectedKey {
                        HStack(spacing: 8) {
                            modifierBadge(selectedModifier == .ctrl ? "Ctrl" : "Alt", active: true)
                            Text(verbatim: "+")
                                .font(Typography.monoSectionRegular)
                                .foregroundColor(SoyehtTheme.textTertiary)
                            keyBadge(String(key).uppercased(), active: true)
                        }
                    } else {
                        Text("settings.shortcut.creator.preview.chooseCombo")
                            .font(Typography.monoLabelRegular)
                            .foregroundColor(SoyehtTheme.textTertiary)
                    }
                } else {
                    if commandText.isEmpty {
                        Text("settings.shortcut.creator.preview.typeCommand")
                            .font(Typography.monoLabelRegular)
                            .foregroundColor(SoyehtTheme.textTertiary)
                    } else {
                        Text(verbatim: "> \(commandText)")
                            .font(Typography.monoBodyMedium)
                            .foregroundColor(SoyehtTheme.historyGreen)
                    }
                }

                Text(previewDescription)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.historyGray)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .overlay(
                Rectangle()
                    .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
            )
        }
    }

    private var previewDescription: String {
        switch mode {
        case .keyCombo:
            guard let key = selectedKey else { return "" }
            let mod = selectedModifier == .ctrl ? "Ctrl" : "Alt"
            let desc = descriptionText.isEmpty ? "" : "  ·  \(descriptionText)"
            return "\(mod)+\(key.uppercased())\(desc)"
        case .textCommand:
            if commandText.isEmpty { return "" }
            let desc = descriptionText.isEmpty ? "" : "  ·  \(descriptionText)"
            return "types \"\(commandText)\"\(desc)"
        }
    }

    // MARK: - Command Section (Text Command mode)

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.shortcut.creator.command.section")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)

            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(Typography.sansBody)
                    .foregroundColor(SoyehtTheme.textTertiary)

                TextField("settings.shortcut.creator.command.placeholder", text: $commandText)
                    .font(Typography.monoCardBody)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color(hex: "#0A0A0A"))
            .overlay(
                Rectangle()
                    .stroke(Color(hex: "#1A1A1A"), lineWidth: 1)
            )

            Text("settings.shortcut.creator.command.footer")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
    }

    // MARK: - Modifier Section

    private var modifierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.shortcut.creator.modifier.section")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)

            HStack(spacing: 6) {
                modifierToggle("Ctrl", modifier: .ctrl)
                modifierToggle("Alt", modifier: .alt)
            }
        }
    }

    private func modifierToggle(_ title: String, modifier: ShortcutBarModifier) -> some View {
        let isSelected = selectedModifier == modifier
        return Button {
            selectedModifier = modifier
        } label: {
            Text(title)
                .font(Typography.mono(size: 12 * Typography.uiScale, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(isSelected ? Color(hex: "#10B981").opacity(0.15) : Color.black)
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? SoyehtTheme.historyGreen : Color(hex: "#1A1A1A"), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Key Grid

    private var keyGridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.shortcut.creator.key.section")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)

            VStack(spacing: 4) {
                keyRow(Array("ABCDEFGHIJ"))
                keyRow(Array("KLMNOPQRST"))
                keyRow(Array("UVWXYZ[]\\/"))
            }
        }
    }

    private func keyRow(_ keys: [Character]) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                keyGridButton(key)
            }
        }
    }

    private func keyGridButton(_ key: Character) -> some View {
        let isSelected = selectedKey == key
        return Button {
            selectedKey = key
        } label: {
            Text(String(key))
                .font(Typography.monoLabel)
                .foregroundColor(isSelected ? SoyehtTheme.historyGreen : SoyehtTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color(hex: "#10B981").opacity(0.12) : Color(hex: "#1A1A1A"))
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? SoyehtTheme.historyGreen : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Label Section

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.shortcut.creator.label.section")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)

            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .font(Typography.sansBody)
                    .foregroundColor(SoyehtTheme.textTertiary)

                TextField("settings.shortcut.creator.label.placeholder", text: $label)
                    .font(Typography.monoCardBody)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                if !label.isEmpty {
                    Spacer()
                } else {
                    Text(autoLabel)
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textTertiary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color(hex: "#0A0A0A"))
            .overlay(
                Rectangle()
                    .stroke(Color(hex: "#1A1A1A"), lineWidth: 1)
            )

            Text("settings.shortcut.creator.label.footer")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.shortcut.creator.description.section")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)

            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(Typography.sansBody)
                    .foregroundColor(SoyehtTheme.textTertiary)

                TextField("settings.shortcut.creator.description.placeholder", text: $descriptionText)
                    .font(Typography.monoLabelRegular)
                    .foregroundColor(SoyehtTheme.historyGray)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Color(hex: "#0A0A0A"))
            .overlay(
                Rectangle()
                    .stroke(Color(hex: "#1A1A1A"), lineWidth: 1)
            )
        }
    }

    // MARK: - Hints Box

    private var hintsBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.shortcut.creator.hints.section")
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.historyGray)

            if mode == .keyCombo {
                Group {
                    Text("settings.shortcut.creator.hint.keyCombo.1")
                    Text("settings.shortcut.creator.hint.keyCombo.2")
                    Text("settings.shortcut.creator.hint.keyCombo.3")
                    Text("settings.shortcut.creator.hint.keyCombo.4")
                }
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textPrimary)
            } else {
                Group {
                    Text("settings.shortcut.creator.hint.textCommand.1")
                    Text("settings.shortcut.creator.hint.textCommand.2")
                    Text("settings.shortcut.creator.hint.textCommand.3")
                    Text("settings.shortcut.creator.hint.textCommand.4")
                }
                .font(Typography.monoSmall)
                .foregroundColor(SoyehtTheme.textPrimary)
            }
        }
        .padding(12)
        .background(Color(hex: "#0A0A0A"))
        .overlay(
            Rectangle()
                .stroke(Color(hex: "#1A1A1A"), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func modifierBadge(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(Typography.monoLabel)
            .foregroundColor(active ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(active ? Color(hex: "#10B981").opacity(0.15) : Color(hex: "#1A1A1A"))
            .overlay(
                Rectangle()
                    .stroke(active ? SoyehtTheme.historyGreen : Color(hex: "#1A1A1A"), lineWidth: 1)
            )
    }

    private func keyBadge(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(Typography.monoLabel)
            .foregroundColor(active ? SoyehtTheme.textPrimary : SoyehtTheme.historyGray)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(Color(hex: "#1A1A1A"))
            .overlay(
                Rectangle()
                    .stroke(active ? SoyehtTheme.textPrimary : Color(hex: "#1A1A1A"), lineWidth: 1)
            )
    }

    // MARK: - Save

    private func saveShortcut() {
        let item: ShortcutBarItem
        switch mode {
        case .keyCombo:
            guard let key = selectedKey else { return }
            item = ShortcutBarItem.customShortcut(
                modifier: selectedModifier,
                key: key,
                label: label.isEmpty ? nil : label,
                description: descriptionText.isEmpty ? nil : descriptionText
            )
        case .textCommand:
            guard !commandText.isEmpty else { return }
            item = ShortcutBarItem.textCommand(
                text: commandText,
                label: label.isEmpty ? nil : label,
                description: descriptionText.isEmpty ? nil : descriptionText
            )
        }
        onSave(item)
        dismiss()
    }
}
