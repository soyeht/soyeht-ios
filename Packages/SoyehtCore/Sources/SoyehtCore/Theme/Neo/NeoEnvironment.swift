import SwiftUI

private struct NeoPaletteKey: EnvironmentKey {
    static let defaultValue = NeoPalette.cloud
}

public extension EnvironmentValues {
    var neoPalette: NeoPalette {
        get { self[NeoPaletteKey.self] }
        set { self[NeoPaletteKey.self] = newValue }
    }
}

public extension View {
    func neoPalette(_ palette: NeoPalette) -> some View {
        environment(\.neoPalette, palette)
    }
}
