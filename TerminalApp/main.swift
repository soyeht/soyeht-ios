import Cocoa
import Foundation

private func normalizeProcessWorkingDirectoryBeforeAppKitLaunch() {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    guard FileManager.default.changeCurrentDirectoryPath(homeDirectory.path) else { return }
    setenv("PWD", homeDirectory.path, 1)
    unsetenv("OLDPWD")
}

MainActor.assumeIsolated {
    normalizeProcessWorkingDirectoryBeforeAppKitLaunch()

    let app = NSApplication.shared
    if Bundle.main.object(forInfoDictionaryKey: "SoyehtUninstallerMode") as? Bool == true {
        let delegate = UninstallCompanionAppDelegate()
        app.delegate = delegate
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
