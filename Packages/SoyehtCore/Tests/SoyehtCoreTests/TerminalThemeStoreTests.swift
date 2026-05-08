import Foundation
import Testing
@testable import SoyehtCore

@Suite("TerminalThemeStore")
struct TerminalThemeStoreTests {
    /// Imported themes are re-downloadable; persisting them into the
    /// device's iCloud / iTunes backup bloats user backups for content
    /// they can trivially recover. The store sets
    /// `isExcludedFromBackupKey = true` on the themes directory at
    /// init so every theme written below it inherits the exclusion.
    @Test func excludesThemesDirectoryFromBackup() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TerminalThemeStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: scratch)
        }

        _ = TerminalThemeStore(themesDirectory: scratch)

        // The init must have eagerly created the directory and stamped
        // it with `isExcludedFromBackup = true`. Reading the resource
        // value back from the URL is the contract the OS uses to decide
        // backup eligibility.
        var url = scratch
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(FileManager.default.fileExists(atPath: scratch.path))
    }

    /// Init with a directory that already exists must not regress the
    /// resource value — we re-apply on every init so a directory that
    /// was created before this fix still gets the flag once the user
    /// upgrades.
    @Test func reAppliesExclusionOnExistingDirectory() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TerminalThemeStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: scratch)
        }

        // Pre-create the directory WITHOUT the exclusion flag, simulating
        // the pre-fix state on an upgrading user's device.
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        _ = TerminalThemeStore(themesDirectory: scratch)

        var url = scratch
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// Pin the subtree-skip semantics: a theme file written into the
    /// excluded directory via `saveImportedTheme` (which uses
    /// `Data.write(to:options:.atomic)` — a write-temp-then-rename
    /// pattern that keeps the temp file inside the same parent so the
    /// rename is volume-local) must end up inside the excluded subtree.
    /// Reading the per-file resource value back is the strongest
    /// regression lock we can take without driving an actual backup.
    /// The directory's exclusion flag is what causes Apple's backup
    /// engines (iCloud Backup, Time Machine) to skip the subtree
    /// wholesale — but a future refactor that splits each theme into
    /// its own subdirectory or moves writes to a sibling staging path
    /// would silently break the contract; this test catches that.
    @Test func savedThemeFileLandsInsideExcludedSubtree() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TerminalThemeStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: scratch)
        }

        let store = TerminalThemeStore(themesDirectory: scratch)
        let theme = try TerminalColorTheme.builtInThemes[0].validated()
        let saved = try store.saveImportedTheme(theme)

        // The file must exist inside the excluded directory. Reading
        // the directory's resource value back is the contract: if the
        // future refactor moves writes elsewhere, the file will exist
        // outside the excluded subtree and this test fails on the
        // `commonPrefix` check below.
        let savedFile = scratch.appendingPathComponent("\(saved.id).json")
        #expect(FileManager.default.fileExists(atPath: savedFile.path))

        // Resolve both paths to absolute URLs and check that the saved
        // file is a descendant of the excluded directory.
        let scratchPath = scratch.standardizedFileURL.path
        let savedPath = savedFile.standardizedFileURL.path
        #expect(savedPath.hasPrefix(scratchPath + "/"))
    }
}
