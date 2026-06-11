import Foundation

#if canImport(AppKit)
import AppKit

enum MainMenuBaseline {
    /// Builds a structural snapshot target for the current public menu surface.
    ///
    /// This is a structural safety net, not a full `NSMenuItemValidation` oracle:
    /// commands that are context-dependent may appear structurally even in the
    /// no-window baseline. Descriptor-level `CommandUIContext` validation owns
    /// enabled/disabled behavior.
    static func makePublicNoWindowMenu(clawStoreEnabled: Bool = false) -> NSMenu {
        MainMenuBuilder().buildPublicNoWindowMenu(clawStoreEnabled: clawStoreEnabled)
    }

    static func snapshotOptions() -> MainMenuSnapshotOptions {
        MainMenuSnapshotOptions(redactedSubmenuTags: [
            MainMenuTag.soundDictationLanguage: "dictation languages are locale and preference dependent"
        ])
    }
}
#endif
