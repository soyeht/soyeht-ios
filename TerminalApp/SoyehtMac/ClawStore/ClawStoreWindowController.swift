import AppKit
import SwiftUI
import SoyehtCore

/// Dedicated NSWindow for the macOS Claw Store. Coexists with the main
/// workspace window — users keep terminals open while browsing/installing
/// claws, which matches the App Store mental model called out in the
/// roadmap (US-06).
@MainActor
final class ClawStoreWindowController: NSWindowController {
    private var context: ServerContext
    private let onOpenTerminal: (String) -> Void
    private let onConnectThisMac: () -> Void
    private let onShowConnectedServers: () -> Void
    private var activeServerObserver: NSObjectProtocol?

    init(
        context: ServerContext,
        onOpenTerminal: @escaping (String) -> Void = { _ in },
        onConnectThisMac: @escaping () -> Void = {},
        onShowConnectedServers: @escaping () -> Void = {}
    ) {
        self.context = context
        self.onOpenTerminal = onOpenTerminal
        self.onConnectThisMac = onConnectThisMac
        self.onShowConnectedServers = onShowConnectedServers
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: context)
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("SoyehtClawStoreWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: makeRootView(context: context))

        // Rebuild the hosted root on active-server changes so target-fixed
        // view models, polling services, readiness state, and navigation paths
        // are recreated for the new ServerContext.
        activeServerObserver = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.activeServerChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let context = MacActiveServerContextResolver.activeContext() else {
                    self.close()
                    return
                }
                self.rebind(to: context)
            }
        }
    }

    func rebind(to newContext: ServerContext) {
        guard context != newContext else { return }
        context = newContext
        window?.title = Self.windowTitle(for: newContext)
        window?.contentViewController = NSHostingController(rootView: makeRootView(context: newContext))
    }

    deinit {
        if let observer = activeServerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ClawStoreWindowController")
    }

    private static func windowTitle(for context: ServerContext) -> String {
        let storeTitle = String(localized: "claw.store.window.title", comment: "Title of the dedicated Claw Store macOS window.")
        return "\(storeTitle) - \(context.server.displayName)"
    }

    private func makeRootView(context: ServerContext) -> MacClawStoreRootView {
        MacClawStoreRootView(
            context: context,
            onOpenTerminal: onOpenTerminal,
            onConnectThisMac: onConnectThisMac,
            onShowConnectedServers: onShowConnectedServers
        )
    }
}
