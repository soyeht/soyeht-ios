import AppKit
import SwiftUI
import SoyehtCore

/// Tells the person when launch could not leave the engine able to hold their
/// terminals.
///
/// Without this the reconciler's bad outcomes went to the unified log and
/// nowhere else. Measured on the owner's machine: the app reported a missing
/// engine on every launch for weeks; he learned of it by losing sessions. A log
/// is where a developer looks *after* being told something is wrong — it is not
/// how a person finds out.
///
/// The window is deliberately small and dismissable. This is not a failure the
/// person caused, and the app keeps working without the engine; it just cannot
/// keep sessions alive across a quit. The tone follows FR-119: never the word
/// "error", always the one thing to do next.
@MainActor
final class EngineRepairWindowController: NSWindowController {

    private static var shared: EngineRepairWindowController?

    /// - Parameters:
    ///   - attention: what to say. `nil` dismisses anything on screen, so a
    ///     later launch that repairs itself clears the message instead of
    ///     leaving a stale warning up.
    ///   - retry: re-runs reconciliation; the window closes if it comes back
    ///     clean.
    static func present(_ attention: EngineServiceReconciler.Attention?,
                        retry: @escaping () -> EngineServiceReconciler.Attention?) {
        guard let attention else {
            shared?.close()
            shared = nil
            return
        }
        if let existing = shared {
            existing.update(attention, retry: retry)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = EngineRepairWindowController(attention: attention, retry: retry)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(attention: EngineServiceReconciler.Attention,
                 retry: @escaping () -> EngineServiceReconciler.Attention?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        update(attention, retry: retry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func update(_ attention: EngineServiceReconciler.Attention,
                        retry: @escaping () -> EngineServiceReconciler.Attention?) {
        let onRetry: () -> Void = { [weak self] in
            // Re-runs the same reconciliation the launch path runs, so the
            // button proves the fix rather than assuming it: the window only
            // closes when reconciliation comes back with nothing to say.
            let remaining = retry()
            if remaining == nil {
                self?.close()
                EngineRepairWindowController.shared = nil
            } else {
                self?.update(remaining!, retry: retry)
            }
        }
        window?.contentView = NSHostingView(
            rootView: EngineNeedsAttentionView(attention: attention, onRetry: onRetry)
        )
    }
}

/// The message itself. One cause, one action.
struct EngineNeedsAttentionView: View {
    let attention: EngineServiceReconciler.Attention
    let onRetry: () -> Void

    var body: some View {
        switch attention {
        case .approvalNeeded:
            // The onboarding flow already says this well; saying it a second
            // way would teach the person two vocabularies for one permission.
            RequiresLoginItemsApprovalView(onRetry: onRetry)
        case .missingFromBundle, .repairFailed:
            plainMessage
        }
    }

    private var plainMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MacTypography.Fonts.Display.heroTitle)
                .foregroundColor(BrandColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
                .foregroundColor(BrandColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 24)

            if attention == .repairFailed {
                Button(action: onRetry) {
                    Text(LocalizedStringResource(
                        "engineRepair.retry",
                        defaultValue: "Try again",
                        comment: "Retries the engine repair after launch could not complete it."
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: LocalizedStringResource {
        switch attention {
        case .repairFailed:
            return LocalizedStringResource(
                "engineRepair.failed.title",
                defaultValue: "Sessions won't survive a quit yet",
                comment: "Shown when launch could not set up the local service that keeps sessions alive."
            )
        case .missingFromBundle, .approvalNeeded:
            return LocalizedStringResource(
                "engineRepair.incomplete.title",
                defaultValue: "This copy of Soyeht is incomplete",
                comment: "Shown when a required file is absent from the app bundle."
            )
        }
    }

    private var message: LocalizedStringResource {
        switch attention {
        case .repairFailed:
            return LocalizedStringResource(
                "engineRepair.failed.body",
                defaultValue: "Soyeht couldn't finish setting up the part that keeps your terminals running when the app closes. Everything still works — but sessions will start fresh after you quit. Try again, or reopen Soyeht later.",
                comment: "Explains the consequence in terms of what the person will notice. Avoids technical wording (FR-119)."
            )
        case .missingFromBundle, .approvalNeeded:
            return LocalizedStringResource(
                "engineRepair.incomplete.body",
                defaultValue: "A file Soyeht needs is missing from the app itself, so it can't set up the part that keeps your terminals running after you quit. Download Soyeht again to replace this copy.",
                comment: "Explains that reinstalling is the fix, without technical wording (FR-119)."
            )
        }
    }
}
