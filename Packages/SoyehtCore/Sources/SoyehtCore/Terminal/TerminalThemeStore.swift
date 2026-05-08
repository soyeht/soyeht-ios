import Foundation

public final class TerminalThemeStore {
    public static let shared = TerminalThemeStore()

    private let fileManager: FileManager
    private let themesDirectory: URL

    public init(
        fileManager: FileManager = .default,
        themesDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        if let themesDirectory {
            self.themesDirectory = themesDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.themesDirectory = base
                .appendingPathComponent("Soyeht", isDirectory: true)
                .appendingPathComponent("Themes", isDirectory: true)
        }
        Self.excludeThemesDirectoryFromBackup(self.themesDirectory, fileManager: fileManager)
    }

    /// Mark the themes directory with `isExcludedFromBackupKey = true`.
    ///
    /// Imported themes are re-downloadable from their source (color theme
    /// JSONs are public, redistributable artifacts), so persisting them
    /// into iCloud + iTunes backups bloats users' backups for content
    /// they can recover trivially. The exclusion applies to the
    /// directory itself; files created inside inherit the flag in
    /// practice on iOS, so individual `theme.write(to:)` calls do not
    /// need to repeat it. Best-effort: if the directory does not exist
    /// yet (first install before the first theme is saved), or the
    /// resource-value set fails for any reason (sandbox quirk, simulator
    /// edge), we swallow — the worst case is the previous behaviour
    /// (themes count toward backup), and the next save attempt will try
    /// again via the post-`createDirectory` re-application.
    private static func excludeThemesDirectoryFromBackup(
        _ url: URL,
        fileManager: FileManager
    ) {
        // Create the directory eagerly so the resource value has a
        // target. `withIntermediateDirectories: true` makes this a no-op
        // if it already exists.
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    public var activeTheme: TerminalColorTheme {
        theme(id: TerminalPreferences.shared.colorTheme)
            ?? TerminalColorTheme.builtInThemes.first(where: { $0.id == ColorTheme.soyehtDark.rawValue })
            ?? TerminalColorTheme.builtInThemes[0]
    }

    public func allThemes() -> [TerminalColorTheme] {
        let installed = installedThemes()
        let installedIDs = Set(installed.map(\.id))
        let builtIns = TerminalColorTheme.builtInThemes.filter { !installedIDs.contains($0.id) }
        return builtIns + installed.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public func installedThemes() -> [TerminalColorTheme] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: themesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let theme = try? decoder.decode(TerminalColorTheme.self, from: data),
                      let validated = try? theme.validated() else {
                    return nil
                }
                return validated
            }
    }

    public func theme(id: String) -> TerminalColorTheme? {
        let target = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return allThemes().first { $0.id == target }
    }

    @discardableResult
    public func saveImportedTheme(_ theme: TerminalColorTheme, replacing existingID: String? = nil) throws -> TerminalColorTheme {
        try save(theme, replacing: existingID, allowingBuiltInReplacement: false)
    }

    @discardableResult
    public func saveCustomTheme(_ theme: TerminalColorTheme, replacing existingID: String? = nil) throws -> TerminalColorTheme {
        var custom = theme
        custom.source = .custom
        return try save(custom, replacing: existingID, allowingBuiltInReplacement: false)
    }

    public func deleteUserTheme(id: String) throws {
        guard !TerminalColorTheme.builtInThemes.contains(where: { $0.id == id }) else { return }
        let url = themeFileURL(id: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if TerminalPreferences.shared.colorTheme == id {
            TerminalPreferences.shared.colorTheme = ColorTheme.soyehtDark.rawValue
        }
    }

    public func setActiveTheme(id: String) {
        TerminalPreferences.shared.colorTheme = id
    }

    private func save(
        _ theme: TerminalColorTheme,
        replacing existingID: String?,
        allowingBuiltInReplacement: Bool
    ) throws -> TerminalColorTheme {
        try fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

        var normalized = try theme.validated()
        let builtInIDs = Set(TerminalColorTheme.builtInThemes.map(\.id))

        if let existingID, !existingID.isEmpty, !builtInIDs.contains(existingID) {
            normalized.id = existingID
        } else if !allowingBuiltInReplacement, builtInIDs.contains(normalized.id) {
            normalized.id = uniqueID(for: "\(normalized.id)-custom")
        } else if existingID == nil, fileManager.fileExists(atPath: themeFileURL(id: normalized.id).path) {
            normalized.id = uniqueID(for: normalized.id)
        }

        normalized = try normalized.validated()

        let data = try JSONEncoder.soyehtThemeEncoder.encode(normalized)
        try data.write(to: themeFileURL(id: normalized.id), options: .atomic)

        if let existingID,
           existingID != normalized.id,
           !builtInIDs.contains(existingID) {
            let oldURL = themeFileURL(id: existingID)
            if fileManager.fileExists(atPath: oldURL.path) {
                try? fileManager.removeItem(at: oldURL)
            }
        }

        return normalized
    }

    private func uniqueID(for base: String) -> String {
        let slug = TerminalColorTheme.slug(base)
        let existing = Set(allThemes().map(\.id))
        if !existing.contains(slug) {
            return slug
        }

        var suffix = 2
        while existing.contains("\(slug)-\(suffix)") {
            suffix += 1
        }
        return "\(slug)-\(suffix)"
    }

    private func themeFileURL(id: String) -> URL {
        themesDirectory.appendingPathComponent("\(TerminalColorTheme.slug(id)).json", isDirectory: false)
    }
}

private extension JSONEncoder {
    static var soyehtThemeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
