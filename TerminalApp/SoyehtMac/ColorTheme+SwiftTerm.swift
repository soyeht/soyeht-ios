import SwiftTerm
import SoyehtCore

extension ColorTheme {
    public var palette: [SwiftTerm.Color] {
        ansiHex.map { hex in
            let (r, g, b) = Self.rgb8(from: hex)
            return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }
    }
}
