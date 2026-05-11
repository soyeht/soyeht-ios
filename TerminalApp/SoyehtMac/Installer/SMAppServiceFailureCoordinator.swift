import Foundation
import os.log

private let log = Logger(subsystem: "com.soyeht.mac", category: "SMAppServiceInstaller")

/// Interprets `SMAppService.register()` failures and produces case-specific
/// `InstallerAction` values that drive UX in `InstallProgressView` per FR-126.
/// Never surfaces the word "erro" (FR-119).
enum SMAppServiceFailureCoordinator {

    enum InstallerAction {
        /// Show `RequiresLoginItemsApprovalView` with animated System Settings arrow.
        case showApprovalUI
        /// Silent retry, then trigger full reinstall if retry also fails.
        case retryThenReinstall
        /// Log diagnostic and retry registration once.
        case logAndRetry
        /// Treat as already-registered (idempotent path).
        case treatAsEnabled
    }

    /// Maps an SMAppService status to the appropriate installer action.
    static func action(for status: SMAppServiceInstaller.InstallerStatus) -> InstallerAction {
        switch status {
        case .requiresApproval:
            return .showApprovalUI
        case .notFound:
            log.error("SMAppService plist not found in bundle — bundle may be incomplete")
            return .retryThenReinstall
        case .notRegistered:
            log.info("SMAppService not registered; will retry once")
            return .logAndRetry
        case .enabled, .unknown:
            return .treatAsEnabled
        }
    }

    /// Convenience: derives action from a thrown `InstallerError`.
    static func action(for error: SMAppServiceInstaller.InstallerError) -> InstallerAction {
        switch error {
        case .requiresApproval:
            return .showApprovalUI
        case .notFound:
            log.error("SMAppService plist not found in app bundle")
            return .retryThenReinstall
        case .registrationDidNotEnable:
            log.info("SMAppService registration completed without enabled status; will retry")
            return .logAndRetry
        case .registrationFailed(let error):
            log.error("SMAppService registration failed: \(String(describing: error), privacy: .public)")
            return .logAndRetry
        }
    }
}
