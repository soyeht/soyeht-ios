import Foundation

/// Facade used by the sidebar "broker inject" input to push a line of text
/// into a running conversation's PTY via its WebSocket. Resolves the live
/// `PaneViewController` through `LivePaneRegistry` and calls its injection
/// method. No-op if the pane is not currently live.
///
/// The concrete injection hook on `PaneViewController` is implemented in
/// Phase 2+ — this file defines the API contract so sidebar code (Phase 9)
/// can compile against it before the pane exists.
@MainActor
enum BrokerInjector {

    /// Send `text` (with trailing newline) into the target conversation's
    /// terminal. Returns true if a live pane was found and the send was
    /// attempted; false otherwise.
    @discardableResult
    static func inject(text: String, into conversationID: Conversation.ID) -> Bool {
        guard let pane = LivePaneRegistry.shared.pane(for: conversationID) else { return false }
        guard let injector = pane as? BrokerInjectable else { return false }
        injector.brokerInject(text.hasSuffix("\n") ? text : text + "\n")
        return true
    }
}

/// Conformed by `PaneViewController` (Phase 2). Kept as a separate protocol so
/// Phase 1 and 9 compile without a hard dependency on the pane class.
@MainActor
protocol BrokerInjectable: AnyObject {
    func brokerInject(_ text: String)
}
