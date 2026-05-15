import Cocoa
import Foundation

private func normalizeProcessWorkingDirectoryBeforeAppKitLaunch() {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    guard FileManager.default.changeCurrentDirectoryPath(homeDirectory.path) else { return }
    setenv("PWD", homeDirectory.path, 1)
    unsetenv("OLDPWD")
}

normalizeProcessWorkingDirectoryBeforeAppKitLaunch()
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
