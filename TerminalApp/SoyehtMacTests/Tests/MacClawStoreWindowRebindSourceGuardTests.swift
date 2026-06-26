import XCTest

/// Source guard for the AppKit-hosted macOS Claw Store window.
///
/// The SwiftPM domain target intentionally does not link the app's AppKit target,
/// so this locks the rebind contract by reading the production sources from disk.
final class MacClawStoreWindowRebindSourceGuardTests: XCTestCase {
    func test_windowControllerRebindsInsteadOfClosingWhenActiveServerContextExists() throws {
        let source = try codeOnly(macSource("ClawStore/ClawStoreWindowController.swift"))
        let observer = try slice(
            source,
            from: "activeServerObserver = NotificationCenter.default.addObserver(",
            to: "func rebind(to newContext: ServerContext)"
        )
        let rebind = try slice(
            source,
            from: "func rebind(to newContext: ServerContext)",
            to: "deinit"
        )

        XCTAssertTrue(source.contains("private var context: ServerContext"))
        XCTAssertTrue(source.contains("private let onOpenTerminal: (String) -> Void"))
        XCTAssertTrue(source.contains("private let onConnectThisMac: () -> Void"))
        XCTAssertTrue(source.contains("private let onShowConnectedServers: () -> Void"))

        XCTAssertTrue(observer.contains("MacActiveServerContextResolver.activeContext()"))
        XCTAssertTrue(observer.contains("self.rebind(to: context)"))
        XCTAssertTrue(observer.contains("self.close()"))

        XCTAssertTrue(rebind.contains("guard context != newContext else { return }"))
        XCTAssertTrue(rebind.contains("context = newContext"))
        XCTAssertTrue(rebind.contains("window?.title = Self.windowTitle(for: newContext)"))
        XCTAssertTrue(rebind.contains("window?.contentViewController = NSHostingController(rootView: makeRootView(context: newContext))"))
    }

    func test_appDelegateRebindsExistingStandaloneStoreAndDoesNotCloseForConnectThisMac() throws {
        let source = try codeOnly(macSource("AppDelegate.swift"))
        let showStandalone = try slice(
            source,
            from: "private func showStandaloneClawStore(context: ServerContext)",
            to: "private func connectThisMacFromClawStore()"
        )
        let existingWindowBranch = try slice(
            showStandalone,
            from: "if let existing = clawStoreWindowController {",
            to: "let wc = ClawStoreWindowController("
        )
        let connectThisMac = try slice(
            source,
            from: "private func connectThisMacFromClawStore()",
            to: "private func closeStandaloneClawStoreWindow()"
        )

        XCTAssertTrue(existingWindowBranch.contains("existing.rebind(to: context)"))
        XCTAssertTrue(existingWindowBranch.contains("existing.showWindow(nil)"))
        XCTAssertTrue(existingWindowBranch.contains("existing.window?.makeKeyAndOrderFront(nil)"))

        XCTAssertFalse(connectThisMac.contains("closeStandaloneClawStoreWindow()"))
        XCTAssertTrue(connectThisMac.contains("SessionStore.shared.setActiveServer(id: localServer.id)"))
        XCTAssertTrue(connectThisMac.contains("DispatchQueue.main.async { [weak self] in"))
        XCTAssertTrue(connectThisMac.contains("self?.showStandaloneClawStore(context: context)"))
    }

    // MARK: - Helpers

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return false }
                if trimmed.hasPrefix("*") { return false }
                if trimmed.hasPrefix("/*") { return false }
                return true
            }
            .joined(separator: "\n")
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
