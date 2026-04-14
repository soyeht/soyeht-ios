import Testing
import UIKit
@testable import Soyeht

@MainActor
@Suite struct ScrollbackPanelAppearanceTests {

    // The outer panel view is intentionally transparent — a private `background`
    // subview carries the theme color so `setContentRevealProgress` can fade it
    // in/out without cross-fading the whole panel. The layers the user actually
    // sees (collection + handle) must paint solid with the theme color so cell
    // gaps and the handle surface never leak the live terminal.
    @Test("Scrollback panel renders its visible layers with the theme background")
    func panelVisibleLayersMatchTheme() {
        let panel = ScrollbackPanelView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        let expected = UIColor(hex: ColorTheme.active.backgroundHex) ?? .black

        #expect(colorsMatch(panel.collectionView.backgroundColor, expected))
        #expect(colorsMatch(panel.handleView.backgroundColor, expected))
    }

    @Test("Scrollback cells paint their full surface with the theme background")
    func cellsUseOpaqueBackground() {
        let cell = ScrollbackLineCell(frame: .init(x: 0, y: 0, width: 320, height: 24))
        cell.configure(attributed: NSAttributedString(string: "history line"))
        let expected = UIColor(hex: ColorTheme.active.backgroundHex) ?? .black

        #expect(cell.isOpaque)
        #expect(colorsMatch(cell.backgroundColor, expected))
        #expect(colorsMatch(cell.contentView.backgroundColor, expected))
    }

    // Positional/layout coverage is intentionally left to manual verification
    // because exercising `ScrollbackPanelController.attach` requires a live
    // SwiftTerm `TerminalView`, which is only linked into the app target.

    private func colorsMatch(_ lhs: UIColor?, _ rhs: UIColor?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }

        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0

        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else {
            return lhs.cgColor == rhs.cgColor
        }

        return abs(lr - rr) < 0.001 &&
            abs(lg - rg) < 0.001 &&
            abs(lb - rb) < 0.001 &&
            abs(la - ra) < 0.001
    }
}
