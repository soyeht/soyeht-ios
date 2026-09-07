import AppKit
import SwiftUI
import SoyehtCore

/// Presents the lifecycle outcome, including a resumable uncertain operation.
/// Closing this window never clears the journal or permits an unsafe CREATE.
@MainActor
final class EngineUpdateWindowController: NSWindowController {
    private static var shared: EngineUpdateWindowController?
    private var completion: (() -> Void)?
    private var working = false

    static func present(_ outcome: EngineReplacementCoordinator.Outcome, onReady: (() -> Void)? = nil) {
        if outcome == .readyWithContinuity || outcome == .readyNoReplacement {
            shared?.close()
            shared = nil
            onReady?()
            return
        }
        let controller = shared ?? EngineUpdateWindowController()
        shared = controller
        if let onReady { controller.completion = onReady }
        controller.update(outcome)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "engineLifecycle.title", defaultValue: "Engine update")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func update(_ outcome: EngineReplacementCoordinator.Outcome) {
        let view = EngineLifecycleView(outcome: outcome, working: working, onClose: { [weak self] in
            self?.close()
        }, onContinue: { [weak self] in self?.advance(outcome) })
        let hosting = NSHostingView(rootView: view)
        window?.contentView = hosting
        window?.setContentSize(hosting.fittingSize)
    }

    private func advance(_ outcome: EngineReplacementCoordinator.Outcome) {
        guard !working else { return }
        switch outcome {
        case .readyWithContinuity, .readyNoReplacement, .readyAfterSupervisorRestart, .readyAfterLegacyMigration:
            let callback = completion
            completion = nil
            close()
            Self.shared = nil
            callback?()
        case .legacyMigrationRequired(let original, let target):
            perform(outcome, resume: false, consent: .init(original: original, target: target))
        case .unconfirmed:
            perform(outcome, resume: true, consent: nil)
        }
    }

    private func perform(_ current: EngineReplacementCoordinator.Outcome, resume: Bool,
                         consent: EngineLifecycleService.MigrationConsent?) {
        working = true
        update(current)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                EngineLifecycleService.run(resume: resume, consent: consent)
            }.value
            guard let self else { return }
            self.working = false
            if result == .readyWithContinuity || result == .readyNoReplacement {
                self.advance(result)
            } else {
                self.update(result)
            }
        }
    }
}

private struct EngineLifecycleView: View {
    let outcome: EngineReplacementCoordinator.Outcome
    let working: Bool
    let onClose: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizedStringResource("engineLifecycle.title", defaultValue: "Engine update"))
                .font(.title2).accessibilityAddTraits(.isHeader)
            Text(message).fixedSize(horizontal: false, vertical: true)
            if working { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                Button(action: onClose) {
                    Text(LocalizedStringResource("engineLifecycle.close", defaultValue: "Close"))
                }.disabled(working)
                Button(role: isLegacy ? .destructive : nil, action: onContinue) {
                    Text(actionLabel)
                }
                .accessibilityIdentifier("engine.lifecycle.continue")
                .disabled(working)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private var isLegacy: Bool {
        if case .legacyMigrationRequired = outcome { return true }
        return false
    }

    private var actionLabel: LocalizedStringResource {
        switch outcome {
        case .legacyMigrationRequired:
            return LocalizedStringResource("engineLifecycle.migrate", defaultValue: "End sessions and update")
        case .unconfirmed:
            return LocalizedStringResource("engineLifecycle.resume", defaultValue: "Resume update")
        case .readyWithContinuity, .readyNoReplacement, .readyAfterSupervisorRestart, .readyAfterLegacyMigration:
            return LocalizedStringResource("engineLifecycle.done", defaultValue: "Done")
        }
    }

    private var message: LocalizedStringResource {
        switch outcome {
        case .legacyMigrationRequired:
            return LocalizedStringResource("engineLifecycle.legacy", defaultValue: "This first update ends all terminal sessions hosted by the current engine, including any opened while this window is visible. Save your work first. After this migration, engine updates preserve sessions through a separate terminal service. Closing this window leaves the current engine running.")
        case .unconfirmed(let reason):
            switch reason {
            case .preparationUnavailable:
                return LocalizedStringResource("engineLifecycle.package", defaultValue: "The update could not verify its files. No new engine was confirmed. Check that this app includes the complete engine package, then resume the update.")
            case .supervisorIncompatible:
                return LocalizedStringResource("engineLifecycle.incompatible", defaultValue: "The running terminal service is incompatible with this update. It has been left running to protect its sessions. Install a compatible app update before resuming.")
            case .originalProcessChanged:
                return LocalizedStringResource("engineLifecycle.changed", defaultValue: "The engine process changed during the update. The earlier approval does not authorize stopping this process. The update remains pending; resume to check whether the intended engine is ready.")
            case .journalUnavailable:
                return LocalizedStringResource("engineLifecycle.journal", defaultValue: "The saved update state could not be read or written safely. New terminal launches remain paused. Resume to recover an interrupted write without forgetting the pending update.")
            default:
                return LocalizedStringResource("engineLifecycle.pending", defaultValue: "The engine update has not been confirmed. The engine may be unavailable and new launches are paused. Resume here to check and continue; restarting the app is not required.")
            }
        case .readyAfterSupervisorRestart:
            return LocalizedStringResource("engineLifecycle.restarted", defaultValue: "The engine is ready. The terminal service restarted during the update, so earlier sessions could not be preserved. You can open new terminals.")
        case .readyAfterLegacyMigration:
            return LocalizedStringResource("engineLifecycle.migrated", defaultValue: "The migration is complete. Sessions from the old engine ended as approved. New terminals now use the independent terminal service and survive engine updates.")
        case .readyNoReplacement:
            return LocalizedStringResource("engineLifecycle.ready", defaultValue: "Ready")
        case .readyWithContinuity:
            return LocalizedStringResource("engineLifecycle.preserved", defaultValue: "The engine is ready and the terminal service stayed running.")
        }
    }
}
