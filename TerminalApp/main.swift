import Cocoa
import Foundation

private func normalizeProcessWorkingDirectoryBeforeAppKitLaunch() {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    guard FileManager.default.changeCurrentDirectoryPath(homeDirectory.path) else { return }
    setenv("PWD", homeDirectory.path, 1)
    unsetenv("OLDPWD")
}

@MainActor
private var retainedApplicationDelegate: (NSObject & NSApplicationDelegate)?

@MainActor
private func runApplication(with delegate: NSObject & NSApplicationDelegate) {
    let app = NSApplication.shared
    // NSApplication does not own its delegate; pin it for the process lifetime.
    retainedApplicationDelegate = delegate
    app.delegate = delegate
    app.run()
}

MainActor.assumeIsolated {
    normalizeProcessWorkingDirectoryBeforeAppKitLaunch()

    if Bundle.main.object(forInfoDictionaryKey: "SoyehtUninstallerMode") as? Bool == true {
        runApplication(with: UninstallCompanionAppDelegate())
    } else {
        runApplication(with: AppDelegate())
    }
}
