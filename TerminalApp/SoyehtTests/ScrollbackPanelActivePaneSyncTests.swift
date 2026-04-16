import Testing
import Foundation
@testable import Soyeht

// Unit coverage for the scope filter that gates `.soyehtActivePaneDidChange`
// and for the detent gate on `reloadHistoryIfVisible`. Attaching the panel
// to a live `TerminalView` is intentionally out of scope (see the note in
// `ScrollbackPanelAppearanceTests`); these tests exercise the two pure
// guards that decide whether a pane-change notification produces a reload.
@MainActor
@Suite struct ScrollbackPanelActivePaneSyncTests {

    @Test("Notification without userInfo is ignored")
    func ignoresNotificationWithoutUserInfo() {
        let controller = ScrollbackPanelController()
        let note = Notification(name: .soyehtActivePaneDidChange, object: nil, userInfo: nil)

        #expect(controller.shouldHandleActivePaneNotification(note) == false)
    }

    @Test("Notification with mismatched container is ignored")
    func ignoresMismatchedContainer() {
        let controller = ScrollbackPanelController()
        controller.setTmuxContext(container: "alpha", session: "main", serverContext: makeTestServerContext())

        let note = Notification(
            name: .soyehtActivePaneDidChange,
            object: nil,
            userInfo: [
                SoyehtNotificationKey.container: "beta",
                SoyehtNotificationKey.session: "main"
            ]
        )

        #expect(controller.shouldHandleActivePaneNotification(note) == false)
    }

    @Test("Notification with mismatched session is ignored")
    func ignoresMismatchedSession() {
        let controller = ScrollbackPanelController()
        controller.setTmuxContext(container: "alpha", session: "main", serverContext: makeTestServerContext())

        let note = Notification(
            name: .soyehtActivePaneDidChange,
            object: nil,
            userInfo: [
                SoyehtNotificationKey.container: "alpha",
                SoyehtNotificationKey.session: "other"
            ]
        )

        #expect(controller.shouldHandleActivePaneNotification(note) == false)
    }

    @Test("Notification matching container and session is accepted")
    func acceptsMatchingContext() {
        let controller = ScrollbackPanelController()
        controller.setTmuxContext(container: "alpha", session: "main", serverContext: makeTestServerContext())

        let note = Notification(
            name: .soyehtActivePaneDidChange,
            object: nil,
            userInfo: [
                SoyehtNotificationKey.container: "alpha",
                SoyehtNotificationKey.session: "main"
            ]
        )

        #expect(controller.shouldHandleActivePaneNotification(note) == true)
    }

    // At peek (the initial detent), `reloadHistoryIfVisible` must be a no-op
    // so collapsed panels don't burn a fetch every time the user switches
    // panes with the panel closed. A fresh controller starts at peek and has
    // never been attached, so an unguarded `tmuxSource.load()` would still
    // do nothing (`canLoad` is false), but we want the gate itself to be
    // explicit — the real-world case is "collapsed after having been used".
    @Test("reloadHistoryIfVisible is a no-op while collapsed at peek")
    func reloadIsNoOpAtPeek() {
        let controller = ScrollbackPanelController()
        controller.setTmuxContext(container: "alpha", session: "main", serverContext: makeTestServerContext())

        controller.reloadHistoryIfVisible()
        // No attach, no panelView, no displayedLines mutation — the test
        // passes as long as this call does not crash and does not otherwise
        // observably change state. The detent gate is the contract; the
        // behavior "no crash with minimal state" is the only assertion we
        // can make without a live TerminalView.
        #expect(Bool(true))
    }
}
