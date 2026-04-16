import SwiftUI
import UIKit
import SoyehtCore

enum SoyehtTheme {
    // MARK: - Backgrounds
    static let bgPrimary    = Color.black
    static let bgSecondary  = Color(hex: "#111111")
    static let bgTertiary   = Color(hex: "#1A1A1A")
    static let bgKeybar     = Color(hex: "#1C1C1E")
    static let bgCard       = Color(hex: "#141414")
    static let bgCardBorder = Color(hex: "#222222")

    // MARK: - Accent
    static let accentGreen    = Color(hex: "#00D9A3")
    static let accentGreenDim = Color(hex: "#00D9A3").opacity(0.3)
    static let accentAmber    = Color(hex: "#F59E0B")
    static let accentRed      = Color(hex: "#EF4444")

    // MARK: - History Mode
    static let historyGreen      = Color(hex: "#10B981")
    static let historyGreenBg    = Color(hex: "#10B981").opacity(0.145)
    static let historyGreenBadge = Color(hex: "#10B981").opacity(0.125)
    static let historyGray       = Color(hex: "#6B7280")
    static let historyControlsBg = Color(hex: "#111111")
    static let historyToggleBg   = Color(hex: "#1A1A1A")
    static let historyHintBg     = Color(hex: "#0F0F0F")

    // MARK: - Pane States
    static let paneActiveBg       = Color(hex: "#10B981").opacity(0.07)
    static let paneActiveBorder   = Color(hex: "#10B981").opacity(0.33)
    static let paneInactiveBg     = Color(hex: "#0C0C0C")
    static let paneInactiveBorder = Color(hex: "#1A1A1A")

    // MARK: - Window Card
    static let windowCardBg       = Color(hex: "#111111")
    static let windowCardBorder   = Color(hex: "#2A2A2A")
    static let tabInactiveBorder  = Color(hex: "#333333")

    // MARK: - Overlay & Controls
    static let overlayBg         = Color.black.opacity(0.7)
    static let progressTrack     = Color.white.opacity(0.1)
    static let buttonTextOnAccent = Color.black

    // MARK: - Text
    static let textPrimary   = Color.white
    static let textSecondary = Color(hex: "#888888")
    static let textTertiary  = Color(hex: "#4B5563")
    static let textComment   = Color(hex: "#666666")
    static let textWarning   = Color(hex: "#FFAA00")

    // MARK: - Status
    static let statusOnline  = Color(hex: "#00D9A3")
    static let statusOffline = Color(hex: "#666666")

    // MARK: - UIKit Colors
    static let uiBgPrimary   = UIColor.black
    static let uiBgKeybar    = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let uiAccentGreen = UIColor(red: 0, green: 0.85, blue: 0.64, alpha: 1)
    static let uiTextPrimary = UIColor.white
    static let uiTextSecondary = UIColor(white: 0.53, alpha: 1)

    // MARK: - Keybar Design Tokens
    static let uiBgKeybarFrame   = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)   // #1A1A1A
    static let uiBgButton        = UIColor(red: 0.165, green: 0.165, blue: 0.165, alpha: 1)   // #2A2A2A
    static let uiDivider         = UIColor(red: 0.227, green: 0.227, blue: 0.227, alpha: 1)   // #3a3a3a
    static let uiTextButton      = UIColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1)   // #FAFAFA
    static let uiTopBorder       = UIColor(red: 0.165, green: 0.165, blue: 0.165, alpha: 1)   // #2a2a2a
    static let uiKillRed         = UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1)   // #EF4444
    static let uiBgKill          = UIColor(red: 0.165, green: 0.102, blue: 0.102, alpha: 1)   // #2A1A1A
    static let uiEnterGreen      = UIColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1)   // #10B981
    static let uiBgEnter         = UIColor(red: 0.102, green: 0.165, blue: 0.102, alpha: 1)   // #1A2A1A
    static let uiScrollBtnBg     = UIColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 0.125) // #10B98120
    static let uiScrollBtnBorder = UIColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1)   // #10B981

    // MARK: - Attachment Picker
    static let uiBgAttachmentPanel = UIColor(red: 0.047, green: 0.047, blue: 0.055, alpha: 1) // #0C0C0E
    static let uiBgAttachmentCard  = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1) // #1A1A1A
    static let uiAttachPhoto       = UIColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1) // #10B981
    static let uiAttachCamera      = UIColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1) // #3B82F6
    static let uiAttachLocation    = UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1) // #EF4444
    static let uiAttachDocument    = UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1) // #F59E0B
    static let uiAttachFiles       = UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1) // #8B5CF6

    // Typography tokens live in `SoyehtCore.Typography` — this file only holds
    // color tokens (SwiftUI Color + UIColor). Call sites use `Typography.mono*`
    // and `Typography.sans*` directly.
}

extension UIColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else { return nil }
        var rgbValue: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgbValue) else { return nil }
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

// `Color.init(hex:)` lives in SoyehtCore (Extensions/Color+Hex.swift) — removed
// from here to avoid ambiguous use when both modules are imported in tests.
