import SwiftTerm
import SoyehtCore

// SwiftTerm color palette — kept here (not in SoyehtCore) because SoyehtCore
// does not depend on SwiftTerm. Mirrors the macOS version at
// TerminalApp/SoyehtMac/ColorTheme+SwiftTerm.swift.

extension TerminalColorTheme {
    public var palette: [SwiftTerm.Color] {
        ansiHex.map { hex in
            let (r, g, b) = ColorTheme.rgb8(from: hex)
            return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }
    }
}

extension ColorTheme {
    public var palette: [SwiftTerm.Color] {
        terminalTheme.palette
    }
}
