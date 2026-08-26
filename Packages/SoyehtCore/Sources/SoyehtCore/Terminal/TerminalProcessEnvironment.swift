import Foundation

public enum TerminalProcessEnvironment {
    private static let inheritedColorOverrideKeys = [
        "NO_COLOR",
        "FORCE_COLOR",
        "CLICOLOR_FORCE",
    ]

    /// `COLORFGBG`, the one signal a program can read without asking.
    ///
    /// The convention is `foreground;background` as ANSI indices, and every
    /// consumer reads only the last field: 0-6 and 8 mean a dark background,
    /// 7 and 9-15 a light one. So `15;0` says light text on dark and `0;15`
    /// says the reverse.
    ///
    /// Soyeht already answers the live question correctly — a program that
    /// sends `OSC 11 ; ? BEL` gets this theme's actual screen colour back —
    /// but a program that never asks had nothing to go on, which is why a
    /// light pane still got a tool's dark styling. This is read at spawn and
    /// cannot follow a later theme change; OSC 11 is the channel that can.
    static func colorForegroundBackground(isDarkBackground: Bool) -> String {
        isDarkBackground ? "15;0" : "0;15"
    }

    /// Process-local Claude Code session markers must never leak into a new
    /// interactive terminal. Soyeht itself is often started or rebuilt from
    /// an agent session; inheriting these values makes a user-typed `claude`
    /// look like a nested child session, disables transcript saving, and can
    /// carry the previous session's private messaging endpoint into an
    /// unrelated pane. User preferences such as `CLAUDE_EFFORT` are
    /// intentionally not removed.
    private static let inheritedClaudeSessionKeys = [
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_PID",
    ]

    public static func interactiveShellEnvironment(
        inherited: [String: String],
        cwdPath: String,
        isDarkBackground: Bool
    ) -> [String: String] {
        var environment = inherited
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["COLORFGBG"] = colorForegroundBackground(isDarkBackground: isDarkBackground)
        environment["PWD"] = cwdPath
        environment.removeValue(forKey: "OLDPWD")
        for key in inheritedColorOverrideKeys {
            environment.removeValue(forKey: key)
        }
        for key in inheritedClaudeSessionKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}
