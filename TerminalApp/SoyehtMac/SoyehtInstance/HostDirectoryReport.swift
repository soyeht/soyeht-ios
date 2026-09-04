import Foundation

/// OSC 7 — the shell telling the terminal which directory it is in.
///
/// Without it a restored pane can only reopen where it was FIRST opened:
/// the app knows the launch directory it asked for and nothing after. The
/// panes here run `/bin/bash`, which announces nothing on its own, so the
/// app injects the report into the prompt it already sets
/// (`NativePTY.resolveSpawnPlan`, shared byte-for-byte with the
/// engine-broker path) and reads it back through SwiftTerm's
/// `hostCurrentDirectoryUpdate`.
///
/// Both halves live here so they cannot drift: the escape that is written
/// and the parser that reads it are one file, one test.
enum HostDirectoryReport {
    /// Prepended to the pane's bash `PS1`, inside `\[ \]` so bash counts it
    /// as zero-width when it measures the prompt.
    ///
    /// `${PWD// /%20}` percent-encodes spaces, the one character that
    /// realistically appears in a Mac path and breaks a URL parse. Anything
    /// else is left as bytes and handled by `localPath(fromOSC7:)`, which
    /// does not require a valid `URL`.
    static let bashPromptPrefix = #"\[\e]7;file://${HOSTNAME}${PWD// /%20}\a\]"#

    /// The absolute local path an OSC 7 payload names, or `nil` when the
    /// payload is not one this app should act on.
    ///
    /// Accepts `file://host/path`, `file:///path` and a bare `/path` (seen
    /// in the wild). The host is ignored: a pane's shell reports its own
    /// machine, and a remote host's path would be meaningless here anyway —
    /// what matters is that the result is absolute.
    ///
    /// Purely syntactic on purpose. Callers that persist the result must
    /// still check the directory exists: a prompt whose parameter expansion
    /// was disabled reports its own source text, and that is not a path.
    static func localPath(fromOSC7 payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }

        let rawPath: String
        if let afterScheme = trimmed.dropSchemePrefix("file://") {
            // Everything up to the first `/` is the authority (possibly
            // empty, as in `file:///Users/…`).
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            rawPath = String(afterScheme[slash...])
        } else if trimmed.hasPrefix("/") {
            rawPath = trimmed
        } else {
            return nil
        }

        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard decoded.hasPrefix("/") else { return nil }
        // A trailing slash is legal in the payload and noise in a stored
        // path; `/` itself keeps its slash.
        if decoded.count > 1, decoded.hasSuffix("/") {
            return String(decoded.dropLast())
        }
        return decoded
    }
}

private extension String {
    /// Case-insensitive scheme match (`FILE://` is legal), returning the
    /// remainder, or `nil` when the prefix is absent.
    func dropSchemePrefix(_ prefix: String) -> Substring? {
        guard count >= prefix.count else { return nil }
        let head = self.prefix(prefix.count)
        guard head.lowercased() == prefix else { return nil }
        return self.dropFirst(prefix.count)
    }
}
