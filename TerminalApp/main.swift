import Cocoa
import Foundation

private func normalizeProcessWorkingDirectoryBeforeAppKitLaunch() {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    guard FileManager.default.changeCurrentDirectoryPath(homeDirectory.path) else { return }
    setenv("PWD", homeDirectory.path, 1)
    unsetenv("OLDPWD")
}

normalizeProcessWorkingDirectoryBeforeAppKitLaunch()

if Bundle.main.object(forInfoDictionaryKey: "SoyehtUninstallerMode") as? Bool == true {
    let app = NSApplication.shared
    let delegate = UninstallCompanionAppDelegate()
    app.delegate = delegate
    app.run()
} else {
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
