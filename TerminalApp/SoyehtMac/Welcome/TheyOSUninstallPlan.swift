import Foundation

struct TheyOSRemovalItem: Equatable {
    let url: URL
    let displayPath: String
}

enum TheyOSUninstallPlan {
    static func removalItems(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local"],
        includeApplicationBundles: Bool = false,
        includeEngine: Bool = true,
        includeUserData: Bool = true,
        includeCachesAndLogs: Bool = true,
        includeMCPArtifacts: Bool = true,
        includePreferences: Bool = true
    ) -> [TheyOSRemovalItem] {
        let home = homeDirectory.standardizedFileURL
        let tmp = temporaryDirectory.standardizedFileURL
        let soyehtSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Soyeht", isDirectory: true)
        let legacyTheyOSSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("theyos", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)

        var items: [TheyOSRemovalItem] = []

        if includeEngine {
            items.append(contentsOf: [
                item(home.appendingPathComponent(".theyos", isDirectory: true), "~/.theyos"),

                item(soyehtSupport.appendingPathComponent("engine", isDirectory: true), "~/Library/Application\\ Support/Soyeht/engine"),
                item(soyehtSupport.appendingPathComponent("bootstrap-token"), "~/Library/Application\\ Support/Soyeht/bootstrap-token"),
                item(soyehtSupport.appendingPathComponent("apns.p8"), "~/Library/Application\\ Support/Soyeht/apns.p8"),
                item(soyehtSupport.appendingPathComponent("identity.bootstrap_state"), "~/Library/Application\\ Support/Soyeht/identity.bootstrap_state"),
                item(soyehtSupport.appendingPathComponent("household.tearing-down"), "~/Library/Application\\ Support/Soyeht/household.tearing-down"),

                item(library.appendingPathComponent("LaunchAgents/com.soyeht.engine.plist"), "~/Library/LaunchAgents/com.soyeht.engine.plist"),
                item(library.appendingPathComponent("LaunchAgents/com.soyeht.caddy.plist"), "~/Library/LaunchAgents/com.soyeht.caddy.plist"),
                item(library.appendingPathComponent("LaunchAgents/com.theyos.cloudflared.plist"), "~/Library/LaunchAgents/com.theyos.cloudflared.plist"),
                item(library.appendingPathComponent("LaunchAgents/homebrew.mxcl.theyos.plist"), "~/Library/LaunchAgents/homebrew.mxcl.theyos.plist"),
            ])
        }

        if includeMCPArtifacts {
            items.append(item(localBin.appendingPathComponent("soyeht-mcp"), "~/.local/bin/soyeht-mcp"))
        }

        if includePreferences {
            items.append(contentsOf: [
                item(library.appendingPathComponent("Preferences/com.soyeht.mac.plist"), "~/Library/Preferences/com.soyeht.mac.plist"),
                item(library.appendingPathComponent("Preferences/com.soyeht.mac.dev.plist"), "~/Library/Preferences/com.soyeht.mac.dev.plist"),
            ])
        }

        let tmpDirectories = [
            tmp,
            URL(fileURLWithPath: "/tmp/", isDirectory: true).standardizedFileURL,
        ].deduplicatedByPath()
        for tmpDirectory in tmpDirectories {
            let displayPrefix = tmpDirectory.path.hasSuffix("/") ? tmpDirectory.path : tmpDirectory.path + "/"
            if includeEngine || includeCachesAndLogs {
                items.append(item(tmpDirectory.appendingPathComponent("soyeht-engine.log"), "\(displayPrefix)soyeht-engine.log"))
            }
            if includeEngine || includeUserData {
                items.append(contentsOf: [
                    item(tmpDirectory.appendingPathComponent("theyos.db"), "\(displayPrefix)theyos.db"),
                    item(tmpDirectory.appendingPathComponent("theyos.db-shm"), "\(displayPrefix)theyos.db-shm"),
                    item(tmpDirectory.appendingPathComponent("theyos.db-wal"), "\(displayPrefix)theyos.db-wal"),
                    item(tmpDirectory.appendingPathComponent("theyos-sessions.db"), "\(displayPrefix)theyos-sessions.db"),
                    item(tmpDirectory.appendingPathComponent("theyos-sessions.db-shm"), "\(displayPrefix)theyos-sessions.db-shm"),
                    item(tmpDirectory.appendingPathComponent("theyos-sessions.db-wal"), "\(displayPrefix)theyos-sessions.db-wal"),
                ])
            }
        }

        if includeApplicationBundles {
            items.append(contentsOf: [
                item(URL(fileURLWithPath: "/Applications/Soyeht.app", isDirectory: true), "/Applications/Soyeht.app"),
                item(home.appendingPathComponent("Applications/Soyeht.app", isDirectory: true), "~/Applications/Soyeht.app"),
                item(URL(fileURLWithPath: "/Applications/Soyeht Dev.app", isDirectory: true), "/Applications/Soyeht\\ Dev.app"),
                item(home.appendingPathComponent("Applications/Soyeht Dev.app", isDirectory: true), "~/Applications/Soyeht\\ Dev.app"),
                item(URL(fileURLWithPath: "/Applications/theyOS.app", isDirectory: true), "/Applications/theyOS.app"),
                item(home.appendingPathComponent("Applications/theyOS.app", isDirectory: true), "~/Applications/theyOS.app"),
            ])
        }

        if includeUserData {
            if includeEngine {
                items.append(item(soyehtSupport, "~/Library/Application\\ Support/Soyeht"))
            }
            items.append(contentsOf: [
                item(library.appendingPathComponent("Application Support/Soyeht QA Backups", isDirectory: true), "~/Library/Application\\ Support/Soyeht\\ QA\\ Backups"),
                item(soyehtSupport.appendingPathComponent("vms", isDirectory: true), "~/Library/Application\\ Support/Soyeht/vms"),
                item(soyehtSupport.appendingPathComponent("snapshots", isDirectory: true), "~/Library/Application\\ Support/Soyeht/snapshots"),
                item(soyehtSupport.appendingPathComponent("conversations", isDirectory: true), "~/Library/Application\\ Support/Soyeht/conversations"),
                item(soyehtSupport.appendingPathComponent("household", isDirectory: true), "~/Library/Application\\ Support/Soyeht/household"),
                item(legacyTheyOSSupport, "~/Library/Application\\ Support/theyos"),
            ])
        }

        if includeCachesAndLogs {
            items.append(contentsOf: [
                item(soyehtSupport.appendingPathComponent("logs", isDirectory: true), "~/Library/Application\\ Support/Soyeht/logs"),
                item(library.appendingPathComponent("Logs/Soyeht", isDirectory: true), "~/Library/Logs/Soyeht"),
                item(home.appendingPathComponent("Library/Logs/theyos", isDirectory: true), "~/Library/Logs/theyos"),
                item(library.appendingPathComponent("Caches/Soyeht", isDirectory: true), "~/Library/Caches/Soyeht"),
                item(library.appendingPathComponent("Caches/com.soyeht.mac", isDirectory: true), "~/Library/Caches/com.soyeht.mac"),
                item(library.appendingPathComponent("Caches/com.soyeht.mac.dev", isDirectory: true), "~/Library/Caches/com.soyeht.mac.dev"),
                item(home.appendingPathComponent("Library/Caches/theyos", isDirectory: true), "~/Library/Caches/theyos"),
                item(home.appendingPathComponent(".cache/theyos", isDirectory: true), "~/.cache/theyos"),
                item(library.appendingPathComponent("HTTPStorages/com.soyeht.mac", isDirectory: true), "~/Library/HTTPStorages/com.soyeht.mac"),
                item(library.appendingPathComponent("HTTPStorages/com.soyeht.mac.dev", isDirectory: true), "~/Library/HTTPStorages/com.soyeht.mac.dev"),
                item(library.appendingPathComponent("Saved Application State/com.soyeht.mac.savedState", isDirectory: true), "~/Library/Saved\\ Application\\ State/com.soyeht.mac.savedState"),
                item(library.appendingPathComponent("Saved Application State/com.soyeht.mac.dev.savedState", isDirectory: true), "~/Library/Saved\\ Application\\ State/com.soyeht.mac.dev.savedState"),
                item(library.appendingPathComponent("WebKit/com.soyeht.mac", isDirectory: true), "~/Library/WebKit/com.soyeht.mac"),
                item(library.appendingPathComponent("WebKit/com.soyeht.mac.dev", isDirectory: true), "~/Library/WebKit/com.soyeht.mac.dev"),
            ])
        }

        if includeEngine || includeUserData {
            for db in engineDatabaseNames {
                for suffix in ["", "-shm", "-wal"] {
                    let filename = db + suffix
                    items.append(item(
                        soyehtSupport.appendingPathComponent(filename),
                        "~/Library/Application\\ Support/Soyeht/\(filename)"
                    ))
                }
            }
        }

        if includeEngine {
            for prefix in homebrewPrefixes {
                let prefixURL = URL(fileURLWithPath: prefix, isDirectory: true)
                items.append(item(prefixURL.appendingPathComponent("opt/theyos"), "\(prefix)/opt/theyos"))
                items.append(item(prefixURL.appendingPathComponent("Cellar/theyos"), "\(prefix)/Cellar/theyos"))
                items.append(item(prefixURL.appendingPathComponent("var/log/theyos.log"), "\(prefix)/var/log/theyos.log"))
            }
        }

        if includeCachesAndLogs {
            items.append(contentsOf: matchingChildren(
                in: library.appendingPathComponent("Application Support/CrashReporter", isDirectory: true),
                prefixes: ["Soyeht", "Soyeht Dev", "theyos-engine"],
                displayDirectory: "~/Library/Application\\ Support/CrashReporter"
            ))
            items.append(contentsOf: matchingChildren(
                in: library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
                prefixes: ["Soyeht", "Soyeht Dev", "ExcUserFault_Soyeht", "theyos-engine"],
                displayDirectory: "~/Library/Logs/DiagnosticReports"
            ))
        }
        if includePreferences {
            items.append(contentsOf: matchingChildren(
                in: library.appendingPathComponent("Preferences", isDirectory: true),
                prefixes: ["com.soyeht.mac.", "com.soyeht.core.tests.", "com.soyeht.tests.", "soyeht.tests."],
                displayDirectory: "~/Library/Preferences"
            ))
        }
        if includeCachesAndLogs {
            items.append(contentsOf: matchingChildren(
                in: library.appendingPathComponent("Cookies", isDirectory: true),
                prefixes: ["com.soyeht.mac"],
                displayDirectory: "~/Library/Cookies"
            ))
            items.append(contentsOf: matchingChildren(
                in: library.appendingPathComponent("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", isDirectory: true),
                prefixes: ["com.soyeht."],
                displayDirectory: "~/Library/Application\\ Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            ))
            items.append(contentsOf: matchingDescendants(
                in: library.appendingPathComponent("Caches/claude-cli-nodejs", isDirectory: true),
                named: "mcp-logs-soyeht",
                displayRoot: "~/Library/Caches/claude-cli-nodejs"
            ))
            items.append(contentsOf: matchingDescendants(
                in: library.appendingPathComponent("Caches/Sparkle_generate_appcast", isDirectory: true),
                named: "Soyeht.app",
                displayRoot: "~/Library/Caches/Sparkle_generate_appcast"
            ))
        }

        return items.deduplicatedByPath()
    }

    private static let engineDatabaseNames = [
        "theyos.db",
        "theyos.sessions.db",
        "theyos.mobile-sessions.db",
        "jobs-rs.db",
        "ratelimit.db",
    ]

    private static func item(_ url: URL, _ displayPath: String) -> TheyOSRemovalItem {
        TheyOSRemovalItem(url: url.standardizedFileURL, displayPath: displayPath)
    }

    private static func matchingChildren(
        in directory: URL,
        prefixes: [String],
        displayDirectory: String
    ) -> [TheyOSRemovalItem] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return children
            .filter { child in
                prefixes.contains { child.lastPathComponent.hasPrefix($0) }
            }
            .map { child in
                item(child, "\(displayDirectory)/\(child.lastPathComponent)")
            }
    }

    private static func matchingDescendants(
        in directory: URL,
        named targetName: String,
        displayRoot: String
    ) -> [TheyOSRemovalItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [TheyOSRemovalItem] = []
        for case let child as URL in enumerator where child.lastPathComponent == targetName {
            result.append(item(
                child,
                "\(displayRoot)/\(child.path.replacingOccurrences(of: directory.path + "/", with: ""))"
            ))
            enumerator.skipDescendants()
        }
        return result
    }
}

enum SoyehtMCPConfigCleaner {
    static func removingSoyehtCodexBlocks(from text: String) -> String {
        let pattern = #"(?m)^\s*\[mcp_servers\.soyeht(?:\.[^\]]*)?\][^\r\n]*(?:\r?\n(?!\s*\[).*)*\r?\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard regex.numberOfMatches(in: text, range: range) > 0 else { return text }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

private extension Array where Element == TheyOSRemovalItem {
    func deduplicatedByPath() -> [TheyOSRemovalItem] {
        var seen: Set<String> = []
        var result: [TheyOSRemovalItem] = []
        for item in self where seen.insert(item.url.path).inserted {
            result.append(item)
        }
        return result
    }
}

private extension Array where Element == URL {
    func deduplicatedByPath() -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in self where seen.insert(url.path).inserted {
            result.append(url)
        }
        return result
    }
}
