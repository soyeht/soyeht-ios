import AppKit
import SwiftUI
import SoyehtCore

/// Tells the person a newer engine is staged, and lets THEM choose when it
/// takes over.
///
/// The engine outlives the app so that sessions survive an app update. An
/// engine update is the one step that cannot keep that promise: every
/// brokered PTY is the engine's child, and a restart ends them all. Before
/// this window, launch bounced a stale engine on its own — measured
/// 2026-09-03 on the owner's machine, the update to 0.1.45 took eight agent
/// sessions one second after the app came back, after the whole point of the
/// broker was that an update never does that.
///
/// The rule since then, pinned in `EngineServiceReconciler.staleEngineAction`:
/// launch may stage the newer engine and may restart it only over nothing.
/// With sessions alive, the restart is a decision, and decisions that end
/// someone's work belong to that someone. The window says what is running,
/// what a restart costs, and what happens if they wait. Never the word
/// "error" (FR-119): nothing is broken.
@MainActor
final class EngineUpdateWindowController: NSWindowController {
    private static var shared: EngineUpdateWindowController?

    /// - Parameters:
    ///   - runningVersion: what the engine answered from `/bootstrap/status`.
    ///   - stagedVersion: what this app ships and now sits in Application
    ///     Support, waiting for the restart.
    ///   - liveSessionCount: how many sessions the restart would end, or
    ///     `nil` when the probe could not say — the copy hedges accordingly
    ///     instead of claiming a number nobody measured.
    static func present(runningVersion: String, stagedVersion: String, liveSessionCount: Int?) {
        let model = EngineUpdateReadyModel(
            runningVersion: runningVersion,
            stagedVersion: stagedVersion,
            liveSessionCount: liveSessionCount
        )
        if let existing = shared {
            existing.update(model)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = EngineUpdateWindowController(model: model)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(model: EngineUpdateReadyModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: EngineUpdateReadyView.contentWidth, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        update(model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func update(_ model: EngineUpdateReadyModel) {
        let dismiss: () -> Void = { [weak self] in
            self?.close()
            EngineUpdateWindowController.shared = nil
        }
        let restart: () -> Void = {
            // The one sanctioned bounce of a live engine, now behind a click
            // that names its cost. The staged binary is already in place, so
            // the service comes back as the newer version.
            SMAppServiceInstaller.restartStaleEngine()
            dismiss()
        }
        let hosting = NSHostingView(
            rootView: EngineUpdateReadyView(model: model, onRestart: restart, onLater: dismiss)
        )
        window?.contentView = hosting
        // Installing a hosting view resizes the window to that view's fitting
        // size; ask for it explicitly so the window is exactly the sheet, then
        // recentre because the size changed under it.
        window?.setContentSize(hosting.fittingSize)
        window?.center()
    }
}

struct EngineUpdateReadyModel: Equatable {
    let runningVersion: String
    let stagedVersion: String
    let liveSessionCount: Int?
}

/// The message itself: what is running, what a restart costs, what waiting
/// means. One decision, two buttons, and the safe one is the default.
struct EngineUpdateReadyView: View {
    let model: EngineUpdateReadyModel
    let onRestart: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource(
                "engineUpdate.ready.title",
                defaultValue: "A newer engine is ready",
                comment: "Shown when the app has staged a newer engine but sessions are running under the current one."
            ))
            .font(MacTypography.Fonts.Display.heroTitle)
            .foregroundColor(BrandColors.textPrimary)
            .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringResource(
                "engineUpdate.ready.later",
                defaultValue: "Nothing changes until you choose. If Soyeht opens with no sessions running, it restarts the engine on its own.",
                comment: "Explains what happens when the person postpones the engine restart."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            Color.clear.frame(height: 24)
            HStack {
                Spacer()
                Button(action: onLater) {
                    Text(LocalizedStringResource(
                        "engineUpdate.ready.button.later",
                        defaultValue: "Later",
                        comment: "Keeps the current engine and its sessions running."
                    ))
                }
                .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: onRestart) {
                    Text(restartButtonTitle)
                }
            }
        }
        .padding(40)
        // Fixed width, content-driven height. An unbounded vertical frame
        // made the hosting view's fitting size unbounded and AppKit sized the
        // window to it: MEASURED 2026-09-04 on the Dev build, 520 x 4224
        // points, with both buttons parked thousands of points below the
        // screen — the person could read the warning and could not answer it.
        .frame(width: Self.contentWidth, alignment: .topLeading)
    }

    /// Shared with the window controller so the sheet and its window cannot
    /// disagree about how wide the text is allowed to be.
    static let contentWidth: CGFloat = 520

    private var message: String {
        let staged = model.stagedVersion
        let running = model.runningVersion
        switch model.liveSessionCount {
        case .some(1):
            return String(localized: LocalizedStringResource(
                "engineUpdate.ready.body.one",
                defaultValue: "Soyeht staged engine \(staged). The one running now is \(running), and 1 terminal session is running under it. Restarting the engine closes that session — an agent working in it stops.",
                comment: "Body of the engine-update window when exactly one session would be closed."
            ))
        case .some(let count):
            return String(localized: LocalizedStringResource(
                "engineUpdate.ready.body.many",
                defaultValue: "Soyeht staged engine \(staged). The one running now is \(running), and \(count) terminal sessions are running under it. Restarting the engine closes all of them — any agent working in those terminals stops.",
                comment: "Body of the engine-update window when several sessions would be closed."
            ))
        case .none:
            return String(localized: LocalizedStringResource(
                "engineUpdate.ready.body.unknown",
                defaultValue: "Soyeht staged engine \(staged). The one running now is \(running), and terminal sessions may be running under it. Restarting the engine closes every one of them — any agent working in those terminals stops.",
                comment: "Body of the engine-update window when the number of sessions could not be counted."
            ))
        }
    }

    private var restartButtonTitle: String {
        switch model.liveSessionCount {
        case .some(1):
            return String(localized: LocalizedStringResource(
                "engineUpdate.ready.button.restart.one",
                defaultValue: "Restart now (closes 1 session)",
                comment: "Restarts the engine, ending the single running session."
            ))
        case .some(let count):
            return String(localized: LocalizedStringResource(
                "engineUpdate.ready.button.restart.many",
                defaultValue: "Restart now (closes \(count) sessions)",
                comment: "Restarts the engine, ending every running session."
            ))
        case .none:
            return String(localized: LocalizedStringResource(
                "engineUpdate.ready.button.restart.unknown",
                defaultValue: "Restart now (closes running sessions)",
                comment: "Restarts the engine when the number of sessions could not be counted."
            ))
        }
    }
}
