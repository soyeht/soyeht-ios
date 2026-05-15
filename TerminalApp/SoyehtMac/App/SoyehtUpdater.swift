import Cocoa
import Sparkle

@MainActor
final class SoyehtUpdater {
    static let shared = SoyehtUpdater()

    private var updaterController: SPUStandardUpdaterController?

    private init() {}

    var isConfigured: Bool {
        configuredInfoValue(forKey: "SUFeedURL") != nil
            && configuredInfoValue(forKey: "SUPublicEDKey") != nil
    }

    var canCheckForUpdates: Bool {
        guard startIfConfigured(), let updaterController else { return false }
        return updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            guard startIfConfigured(), let updaterController else { return false }
            return updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            guard startIfConfigured(), let updaterController else { return }
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    @discardableResult
    func startIfConfigured() -> Bool {
        guard isConfigured else { return false }
        if updaterController == nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        return updaterController != nil
    }

    func checkForUpdates(_ sender: Any?) {
        guard startIfConfigured(), let updaterController else {
            NSSound.beep()
            return
        }
        updaterController.checkForUpdates(sender)
    }

    private func configuredInfoValue(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
