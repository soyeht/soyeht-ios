import AppKit

struct PaneHeaderAccessories: OptionSet {
    let rawValue: Int

    static let qr = PaneHeaderAccessories(rawValue: 1 << 0)
    /// Retired from the visible pane header in favor of the orchestrator
    /// toggle. Keep the bit temporarily so the remaining handoff code can be
    /// removed in a dedicated cleanup without conflating that deletion with
    /// the header-control change.
    static let openOnIPhone = PaneHeaderAccessories(rawValue: 1 << 1)
    static let orchestrationManager = PaneHeaderAccessories(rawValue: 1 << 2)

    static let terminalDefault: PaneHeaderAccessories = [.qr, .orchestrationManager]
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
