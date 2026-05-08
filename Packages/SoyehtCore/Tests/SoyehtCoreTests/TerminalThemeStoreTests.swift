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
}
