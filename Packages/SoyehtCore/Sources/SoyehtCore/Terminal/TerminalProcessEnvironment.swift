import Foundation

public enum TerminalProcessEnvironment {
    private static let inheritedColorOverrideKeys = [
        "NO_COLOR",
        "FORCE_COLOR",
        "CLICOLOR_FORCE",
    ]

    public static func interactiveShellEnvironment(
        inherited: [String: String],
        cwdPath: String
    ) -> [String: String] {
        var environment = inherited
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = cwdPath
        environment.removeValue(forKey: "OLDPWD")
        for key in inheritedColorOverrideKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}
