//
//  AppDelegate.swift
//  MacTerminal
//

import Cocoa
import SoyehtCore

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    // Strong references to all open window controllers.
    // NSWindow.windowController is weak, so without this the WC is immediately deallocated.
    private var windowControllers: [NSWindowController] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        openNewLocalShellWindow()
        // Show login sheet if no server is paired yet
        if SessionStore.shared.pairedServers.isEmpty {
            Task { @MainActor in
                // Yield one run-loop cycle so makeKeyAndOrderFront has time to process
                // before we try to attach a sheet (NSApp.keyWindow needs to be set first).
                await Task.yield()
                self.showLoginSheet()
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Terminal apps stay running after last window closes
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false  // Don't present Open dialog on launch
    }

    // MARK: - URL Scheme (theyos://)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let result = QRScanResult.from(url: url) else { return }
        switch result {
        case .pair(let token, let host), .connect(let token, let host), .invite(let token, let host):
            autoConnect(token: token, host: host)
        }
    }

    /// Directly calls pairServer without showing a sheet — used when a theyos:// link
    /// is opened, since the user deliberately triggered it.
    private func autoConnect(token: String, host: String) {
        Task { @MainActor in
            do {
                _ = try await SoyehtAPIClient.shared.pairServer(token: token, host: host)
                // Dismiss any open login windows/sheets
                for window in NSApp.windows {
                    if window.contentViewController is LoginViewController {
                        window.close()
                    }
                    window.sheets.forEach { sheet in
                        if sheet.contentViewController is LoginViewController {
                            window.endSheet(sheet)
                        }
                    }
                }
            } catch {
                // Fall back to pre-filled sheet so the user can retry
                showLoginSheet(prefillHost: host, prefillToken: token)
            }
        }
    }

    // MARK: - Startup

    @MainActor
    private func startupFlow() async {
        let store = SessionStore.shared
        if store.pairedServers.isEmpty {
            openNewLocalShellWindow()
            await Task.yield()
            showLoginSheet()
        } else {
            openNewLocalShellWindow()
        }
    }

    // MARK: - Window Management

    @discardableResult
    func openNewLocalShellWindow() -> LocalShellWindowController {
        let wc = makeLocalShellWC()
        wc.showWindow(nil)
        return wc
    }

    /// Creates and retains a LocalShellWindowController WITHOUT showing it.
    /// Callers that need to add the window to a tab group before showing should use this.
    @discardableResult
    func makeLocalShellWC() -> LocalShellWindowController {
        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        let wc = storyboard.instantiateController(withIdentifier: "LocalShellWindowController") as! LocalShellWindowController
        retain(wc)
        return wc
    }

    func openSoyehtTab(instance: SoyehtInstance, wsURL: String, sessionName: String) {
        let wc = SoyehtTerminalWindowController(instance: instance, wsURL: wsURL, sessionName: sessionName)
        retain(wc)
        // Use the frontmost REGULAR window (not a popover/panel/sheet) as the tab group anchor.
        // NSApp.keyWindow may be the instance picker popover at this point.
        let anchor = NSApp.windows.first(where: { w in
            w.isVisible && !w.isSheet && w.styleMask.contains(.titled)
            && !(w.contentViewController is InstancePickerViewController)
        })
        if let anchor {
            anchor.addTabbedWindow(wc.window!, ordered: .above)
            wc.window?.makeKeyAndOrderFront(nil)
        } else {
            wc.showWindow(nil)
        }
    }

    private func retain(_ wc: NSWindowController) {
        windowControllers.append(wc)
        if let window = wc.window {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window, queue: .main) { [weak self, weak wc] _ in
                self?.windowControllers.removeAll(where: { $0 === wc })
            }
        }
    }

    @IBAction func showPreferences(_ sender: Any) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @IBAction func newWindow(_ sender: Any) {
        openNewLocalShellWindow()
    }

    @IBAction func newSoyehtTab(_ sender: Any) {
        // Find a LocalShellWindowController to show the picker from, or the key window
        let localShellWC = windowControllers.compactMap { $0 as? LocalShellWindowController }.first
        if let wc = localShellWC {
            wc.showInstancePicker(sender)
        } else {
            // No local shell — open one first, then show picker
            let wc = openNewLocalShellWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                wc.showInstancePicker(sender)
            }
        }
    }

    @IBAction func logout(_ sender: Any) {
        let store = SessionStore.shared
        guard !store.pairedServers.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Logout from Soyeht Server?"
        alert.informativeText = "This will remove your session. You'll need to enter your host and token again to reconnect."
        alert.addButton(withTitle: "Logout")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let id = store.activeServerId {
            store.removeServer(id: id)
        } else {
            store.clearSession()
        }
        showLoginSheet()
    }

    // MARK: - Auth Sheet

    func showLoginSheet(prefillHost: String? = nil, prefillToken: String? = nil) {
        let loginVC = LoginViewController()
        loginVC.onSuccess = {
            // After successful login, the window is already open
        }

        if let host = prefillHost, let token = prefillToken {
            loginVC.prefill(host: host, token: token)
        }

        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.contentViewController?.presentAsSheet(loginVC)
        } else {
            // No window yet — present as standalone panel
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Connect to Soyeht Server"
            panel.contentViewController = loginVC
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
