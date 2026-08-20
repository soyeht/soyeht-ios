import Foundation

/// Which MCP launcher a Soyeht build owns.
///
/// The release build and the development build both install an MCP launcher
/// into `~/.local/bin` and both claim a server key inside the person's agent
/// configuration. While they shared one name, whichever app installed last
/// silently repointed every agent at that bundle — and a development build is
/// rebuilt and relaunched all day, so each relaunch killed the stdio server
/// the person's real agents were talking to.
///
/// Keying on the bundle identifier separates them with no build setting: the
/// release bundle is `com.soyeht.mac`, the development bundle is
/// `com.soyeht.mac.dev`. Everything else — the launcher path, the config key
/// and the uninstall plan — is derived from here, so the two can never collide
/// by only half of the naming being updated.
enum MCPLauncherIdentity: Equatable {
    case release
    case development

    /// Any bundle identifier ending in `.dev` is a development build. An
    /// absent identifier is treated as release: it is the conservative
    /// reading, because a release launcher is what an installed app owns.
    static func forBundle(identifier: String?) -> MCPLauncherIdentity {
        (identifier ?? "").hasSuffix(".dev") ? .development : .release
    }

    static var current: MCPLauncherIdentity {
        forBundle(identifier: Bundle.main.bundleIdentifier)
    }

    /// The server name written into each agent's configuration.
    var configKey: String {
        switch self {
        case .release: return "soyeht"
        case .development: return "soyeht-dev"
        }
    }

    /// The file installed into `~/.local/bin`.
    var launcherFilename: String {
        switch self {
        case .release: return "soyeht-mcp"
        case .development: return "soyeht-dev-mcp"
        }
    }

    /// Every launcher filename the product has ever owned. The uninstaller
    /// removes all of them, so a teardown started from either bundle leaves
    /// nothing behind and never deletes only the other bundle's launcher.
    static var allLauncherFilenames: [String] {
        [MCPLauncherIdentity.release, .development].map(\.launcherFilename)
    }
}
