import SwiftUI
import UIKit

enum SoyehtTheme {
    // MARK: - Backgrounds
    static let bgPrimary    = Color(hex: "#0A0A0A")
    static let bgSecondary  = Color(hex: "#111111")
    static let bgTertiary   = Color(hex: "#1A1A1A")
    static let bgKeybar     = Color(hex: "#1C1C1E")
    static let bgCard       = Color(hex: "#141414")
    static let bgCardBorder = Color(hex: "#222222")

    // MARK: - Accent
    static let accentGreen    = Color(hex: "#00D9A3")
    static let accentGreenDim = Color(hex: "#00D9A3").opacity(0.3)

    // MARK: - Text
    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: "#888888")
    static let textComment   = Color(hex: "#666666")
    static let textWarning   = Color(hex: "#FFAA00")

    // MARK: - Status
    static let statusOnline  = Color(hex: "#00D9A3")
    static let statusOffline = Color(hex: "#666666")

    // MARK: - UIKit Colors
    static let uiBgPrimary   = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
    static let uiBgKeybar    = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let uiAccentGreen = UIColor(red: 0, green: 0.85, blue: 0.64, alpha: 1)
    static let uiTextPrimary = UIColor.white
    static let uiTextSecondary = UIColor(white: 0.53, alpha: 1)

    // MARK: - Typography
    static let titleFont    = Font.system(size: 28, weight: .bold, design: .monospaced)
    static let subtitleFont = Font.system(size: 14, weight: .regular, design: .default)
    static let bodyMono     = Font.system(size: 14, weight: .regular, design: .monospaced)
    static let labelFont    = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let tagFont      = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let smallMono    = Font.system(size: 10, weight: .regular, design: .monospaced)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
