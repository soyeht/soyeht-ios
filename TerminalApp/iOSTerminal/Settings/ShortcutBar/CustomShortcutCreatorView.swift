import SwiftUI

struct CustomShortcutCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedModifier: ShortcutBarModifier = .ctrl
    @State private var selectedKey: Character? = nil
    @State private var label = ""
    @State private var descriptionText = ""

    var onSave: (ShortcutBarItem) -> Void

    private var isValid: Bool { selectedKey != nil }

    private var previewLabel: String {
        guard let key = selectedKey else { return "..." }
        let mod = selectedModifier == .ctrl ? "Ctrl" : "Alt"
        return "\(mod)+\(key.uppercased())"
    }

    private var autoLabel: String {
        guard let key = selectedKey else { return "" }
        let lowered = key.lowercased()
        return selectedModifier == .ctrl ? "C-\(lowered)" : "M-\(lowered)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewBox
                        Spacer().frame(height: 4)
                        modifierSection
                        Spacer().frame(height: 4)
                        keyGridSection
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
            Button("Cancel") { dismiss() }
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(SoyehtTheme.historyGray)

            Spacer()

            Text("New Shortcut")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Button("Save") { saveShortcut() }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(isValid ? SoyehtTheme.historyGreen : SoyehtTheme.historyGray)
                .disabled(!isValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "#0A0A0A"))
    }

    // MARK: - Preview Box

    private var previewBox: some View {
        VStack(spacing: 8) {
            Text("// preview")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(SoyehtTheme.historyGray)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                // Key combo badges
                if let key = selectedKey {
                    HStack(spacing: 8) {
                        modifierBadge(selectedModifier == .ctrl ? "Ctrl" : "Alt", active: true)
                        Text("+")
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(SoyehtTheme.textTertiary)
                        keyBadge(String(key).uppercased(), active: true)
                    }
                } else {
                    Text("Select a modifier and key")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(SoyehtTheme.textTertiary)
                }

                // Description preview
                Text(previewDescription)
                    .font(.system(size: 10, design: .monospaced))
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
        guard let key = selectedKey else { return "" }
        let mod = selectedModifier == .ctrl ? "Ctrl" : "Alt"
        let desc = descriptionText.isEmpty ? "" : "  ·  \(descriptionText)"
        return "\(mod)+\(key.uppercased())\(desc)"
    }

    // MARK: - Modifier Section

    private var modifierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("// modifier")
                .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 12, weight: isSelected ? .medium : .regular, design: .monospaced))
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
            Text("// choose a key")
                .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
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
            Text("// toolbar button name")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(SoyehtTheme.historyGray)

            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .font(.system(size: 14))
                    .foregroundColor(SoyehtTheme.textTertiary)

                TextField("auto", text: $label)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                if !label.isEmpty {
                    Spacer()
                } else {
                    Text(autoLabel)
                        .font(.system(size: 10, design: .monospaced))
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

            Text("Name shown on the button. Leave empty for auto.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(SoyehtTheme.textTertiary)
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("// what does this shortcut do?")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(SoyehtTheme.historyGray)

            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14))
                    .foregroundColor(SoyehtTheme.textTertiary)

                TextField("Description (optional)", text: $descriptionText)
                    .font(.system(size: 12, design: .monospaced))
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
            Text("// hints")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(SoyehtTheme.historyGray)

            Group {
                Text("Ctrl+C  interrupt process")
                Text("Ctrl+D  send EOF (exit shell)")
                Text("Ctrl+Z  suspend process")
                Text("Alt+X   emacs execute-command")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(SoyehtTheme.textPrimary)
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
            .font(.system(size: 12, weight: .medium, design: .monospaced))
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
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(active ? SoyehtTheme.textPrimary : SoyehtTheme.historyGray)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(active ? Color(hex: "#1A1A1A") : Color(hex: "#1A1A1A"))
            .overlay(
                Rectangle()
                    .stroke(active ? SoyehtTheme.textPrimary : Color(hex: "#1A1A1A"), lineWidth: 1)
            )
    }

    // MARK: - Save

    private func saveShortcut() {
        guard let key = selectedKey else { return }
        let item = ShortcutBarItem.customShortcut(
            modifier: selectedModifier,
            key: key,
            label: label.isEmpty ? nil : label,
            description: descriptionText.isEmpty ? nil : descriptionText
        )
        onSave(item)
        dismiss()
    }
}
