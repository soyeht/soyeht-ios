import AppKit

struct PaneHeaderAccessories: OptionSet {
    let rawValue: Int

    static let qr = PaneHeaderAccessories(rawValue: 1 << 0)
    static let openOnIPhone = PaneHeaderAccessories(rawValue: 1 << 1)

    static let terminalDefault: PaneHeaderAccessories = [.qr, .openOnIPhone]
    static let specialDefault: PaneHeaderAccessories = []
}

@MainActor
protocol PaneContentViewControlling: AnyObject {
    var paneID: Conversation.ID { get }
    var contentKind: PaneContentKind { get }
    var matchingKey: String { get }
    var headerTitle: String { get }
    var headerSubtitle: String? { get }
    var headerAccessories: PaneHeaderAccessories { get }

    func focusContent()
    func applyTheme()
    func updateContent(_ content: PaneContent)
    func prepareForClose()
}

extension PaneContentViewControlling {
    func updateContent(_ content: PaneContent) {}
}
