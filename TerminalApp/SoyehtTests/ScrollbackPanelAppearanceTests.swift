import Testing
import UIKit
@testable import Soyeht

@MainActor
@Suite struct ScrollbackPanelAppearanceTests {

    @Test("Scrollback panel uses an opaque theme background across all visible layers")
    func panelLayersAreOpaque() {
        let panel = ScrollbackPanelView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        let expected = UIColor(hex: ColorTheme.active.backgroundHex) ?? .black

        #expect(panel.isOpaque)
        #expect(colorsMatch(panel.backgroundColor, expected))
        #expect(panel.collectionView.isOpaque)
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

    @Test("Scrollback panel stays pinned to the host top edge")
    func panelStaysPinnedToHostTop() {
        let host = UIView(frame: .init(x: 0, y: 0, width: 320, height: 640))
        let terminalView = TerminalView(frame: host.bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: host.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        let controller = ScrollbackPanelController()
        controller.attach(to: host, terminalView: terminalView, topAnchor: host.topAnchor)
        host.layoutIfNeeded()

        guard let panel = controller.panelView else {
            Issue.record("Expected scrollback panel to be attached")
            return
        }

        #expect(abs(panel.frame.minY) < 0.001)
    }

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
