import SwiftUI
import SoyehtCore

struct CustomColorPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var red: Double
    @State private var green: Double
    @State private var blue: Double
    @State private var hexInput: String
    @State private var recentColors: [String]
    @State private var isUpdatingFromSliders = false

    init() {
        let hex = TerminalPreferences.shared.cursorColorHex
        let (r, g, b) = Self.rgbFromHex(hex)
        _red = State(initialValue: r)
        _green = State(initialValue: g)
        _blue = State(initialValue: b)
        _hexInput = State(initialValue: hex.replacingOccurrences(of: "#", with: "").uppercased())
        _recentColors = State(initialValue: TerminalPreferences.shared.recentCustomColors)
    }

    private var currentColor: Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    private var currentHex: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

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

                    Text("settings.customColor.title")
                        .font(Typography.monoBodyMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("settings.customColor.section")
                            .font(Typography.monoLabel)
                            .foregroundColor(SoyehtTheme.historyGray)

                        // Preview card
                        VStack(spacing: 8) {
                            Text(verbatim: "\u{2588}")
                                .font(Typography.monoDisplayHuge)
                                .foregroundColor(currentColor)

                            Text("settings.customColor.preview")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .background(Color(hex: "#0A0A0A"))
                        .overlay(
                            Rectangle()
                                .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                        )

                        // HEX input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("settings.customColor.hexCode")
                                .font(Typography.monoTag)
                                .foregroundColor(SoyehtTheme.historyGray)

                            HStack(spacing: 0) {
                                Text("#")  // i18n-exempt: hex-color prefix, universal
                                    .font(Typography.monoBody)
                                    .foregroundColor(SoyehtTheme.historyGray)
                                    .padding(.leading, 14)

                                TextField("", text: $hexInput)
                                    .font(Typography.monoBody)
                                    .foregroundColor(SoyehtTheme.textPrimary)
                                    .autocapitalization(.allCharacters)
                                    .disableAutocorrection(true)
                                    .padding(.leading, 4)
                                    .padding(.trailing, 14)
                                    .onChange(of: hexInput) { newValue in
                                        let filtered = String(newValue.filter { $0.isHexDigit }.prefix(6)).uppercased()
                                        if filtered != newValue {
                                            hexInput = filtered
                                        }
                                        guard !isUpdatingFromSliders, filtered.count == 6 else { return }
                                        let (r, g, b) = Self.rgbFromHex("#\(filtered)")
                                        red = r
                                        green = g
                                        blue = b
                                    }
                            }
                            .frame(height: 44)
                            .background(Color(hex: "#0A0A0A"))
                            .overlay(
                                Rectangle()
                                    .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
                            )
                        }

                        // RGB Sliders
                        VStack(spacing: 14) {
                            rgbSliderRow(label: "R", value: $red, color: .red)
                            rgbSliderRow(label: "G", value: $green, color: .green)
                            rgbSliderRow(label: "B", value: $blue, color: .blue)
                        }
                        .onChange(of: red) { _ in updateHexFromSliders() }
                        .onChange(of: green) { _ in updateHexFromSliders() }
                        .onChange(of: blue) { _ in updateHexFromSliders() }

                        // Recent colors
                        if !recentColors.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("settings.customColor.recent")
                                    .font(Typography.monoTag)
                                    .foregroundColor(SoyehtTheme.historyGray)

                                HStack(spacing: 12) {
                                    ForEach(recentColors, id: \.self) { hex in
                                        Button {
                                            applyHex(hex)
                                        } label: {
                                            Rectangle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 32, height: 32)
                                                .overlay(
                                                    Rectangle()
                                                        .stroke(
                                                            hex.caseInsensitiveCompare(currentHex) == .orderedSame
                                                                ? Color.white : SoyehtTheme.bgTertiary,
                                                            lineWidth: hex.caseInsensitiveCompare(currentHex) == .orderedSame ? 2 : 1
                                                        )
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        Spacer().frame(height: 20)

                        // Apply button
                        Button {
                            let hex = currentHex
                            TerminalPreferences.shared.cursorColorHex = hex
                            TerminalPreferences.shared.addRecentCustomColor(hex)
                            NotificationCenter.default.post(name: .soyehtCursorColorChanged, object: nil)
                            dismiss()
                        } label: {
                            Text("settings.customColor.apply")
                                .font(Typography.monoBodySemi)
                                .foregroundColor(SoyehtTheme.historyGreen)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(hex: "#1A2A1A"))
                                .overlay(
                                    Rectangle()
                                        .stroke(SoyehtTheme.historyGreen, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - RGB Slider Row

    private func rgbSliderRow(label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Typography.monoTagSemi)
                .foregroundColor(SoyehtTheme.historyGray)
                .frame(width: 16)

            Slider(value: value, in: 0...255, step: 1)
                .tint(color)

            Text(String(format: "%.0f", value.wrappedValue))
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.historyGray)
                .frame(width: 28, alignment: .trailing)
        }
        .frame(height: 32)
    }

    // MARK: - Helpers

    private func updateHexFromSliders() {
        isUpdatingFromSliders = true
        hexInput = String(format: "%02X%02X%02X", Int(red), Int(green), Int(blue))
        isUpdatingFromSliders = false
    }

    private func applyHex(_ hex: String) {
        let (r, g, b) = Self.rgbFromHex(hex)
        red = r
        green = g
        blue = b
        hexInput = hex.replacingOccurrences(of: "#", with: "").uppercased()
    }

    static func rgbFromHex(_ hex: String) -> (Double, Double, Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6 else { return (16, 185, 129) }
        var rgbValue: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&rgbValue) else { return (16, 185, 129) }
        return (
            Double((rgbValue & 0xFF0000) >> 16),
            Double((rgbValue & 0x00FF00) >> 8),
            Double(rgbValue & 0x0000FF)
        )
    }
}
