import Foundation
import XCTest
@testable import SoyehtMacDomain

/// Installing is now two steps: read what the bundle declares, show it, and
/// only then copy. These tests cover the two properties that split creates —
/// a bundle cannot declare its own provenance, and consent does not carry over
/// to a bundle that changed after it was shown.
final class AppInstallInspectionTests: XCTestCase {
    private let manifestJSON = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme"},"capabilities":[],"optionalCapabilities":[]}"#

    private func manifest(_ json: String? = nil) throws -> AppManifest {
        try AppManifest.decode(Data((json ?? manifestJSON).utf8))
    }

    private func variant(replacing needle: String, with replacement: String) throws -> AppManifest {
        let raw = manifestJSON.replacingOccurrences(of: needle, with: replacement)
        XCTAssertNotEqual(raw, manifestJSON, "a agulha não casou; o teste não exerceria nada")
        return try AppManifest.decode(Data(raw.utf8))
    }

    // MARK: - Provenance is decided by the installer, never declared
    //
    // Honest note on what these two prove TODAY: `AppProvenance` has a single
    // case, so provenance cannot come out wrong — no mutant can turn them red,
    // and I checked. They are here as executable intent for the day a second
    // case exists (signed, store-reviewed), because that is the change that
    // makes "derive it from the manifest" look reasonable to whoever writes it.
    // Until then the real guarantee is the single-case enum, not these.

    func testProvenanceIsLocalUnverifiedWhateverTheBundleSays() throws {
        let inspection = AppBundleInspection(source: URL(fileURLWithPath: "/var/empty/candidate"),
                                             manifest: try manifest())
        XCTAssertEqual(inspection.provenance, .localUnverified)
    }

    /// The publisher block is the field a bundle would use to look official.
    /// Changing it must not move provenance, because nothing about it is checked.
    func testAConvincingPublisherDoesNotChangeProvenance() throws {
        let official = try variant(replacing: #""displayName":"Acme""#, with: #""displayName":"Apple Inc.""#)
        let inspection = AppBundleInspection(source: URL(fileURLWithPath: "/var/empty/candidate"),
                                             manifest: official)
        XCTAssertEqual(inspection.provenance, .localUnverified)
    }

    func testProvenanceCannotBeAnythingElseByConstruction() {
        XCTAssertEqual(AppProvenance.allCases, [.localUnverified],
                       "acrescentar um caso de proveniência é mudança de contrato: a partir daí os dois testes acima passam a poder ficar vermelhos, e a interface deixa de poder dizer NOT VERIFIED sem olhar")
    }

    // MARK: - The guard is reached from the commit path
    //
    // Measured before writing this: deleting the `requireUnchanged` CALL from
    // the install path killed nothing. The pure guard was tested and its only
    // caller was not, which is a guard that exists and never runs.

    func testTheCommitPathCallsTheChangeGuard() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac/AppPlatform/AppInstallStore.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("try requireUnchanged(inspected: accepted, atCommit: manifest)"),
                      "o caminho de commit tem de comparar o manifesto aceite com o lido no momento de copiar")
    }

    // MARK: - Consent covers the bundle that was shown, not the folder

    func testCommitAcceptsTheManifestThatWasInspected() throws {
        XCTAssertNoThrow(try AppInstallStore.requireUnchanged(inspected: try manifest(),
                                                              atCommit: try manifest()))
    }

    /// The capability list is the part worth swapping: the person accepted an
    /// app that asked for nothing, and the folder now asks for metrics.
    func testCommitRefusesWhenCapabilitiesChangedAfterInspection() throws {
        let shown = try manifest()
        let swapped = try variant(replacing: #""capabilities":[]"#,
                                  with: #""capabilities":["metrics.read"]"#)
        XCTAssertThrowsError(try AppInstallStore.requireUnchanged(inspected: shown, atCommit: swapped)) { error in
            XCTAssertEqual(error as? AppInstallStore.InstallError, .bundleChangedSinceInspection)
        }
    }

    /// Not only capabilities: the entry point decides which file is served, so
    /// a swap there is a different app behind an accepted name.
    func testCommitRefusesWhenTheEntryPointChangedAfterInspection() throws {
        let shown = try manifest()
        let swapped = try variant(replacing: #""entry":"index.html""#, with: #""entry":"other.html""#)
        XCTAssertThrowsError(try AppInstallStore.requireUnchanged(inspected: shown, atCommit: swapped)) { error in
            XCTAssertEqual(error as? AppInstallStore.InstallError, .bundleChangedSinceInspection)
        }
    }

    func testCommitRefusesWhenTheDeclaredIdentityChangedAfterInspection() throws {
        let shown = try manifest()
        let swapped = try variant(replacing: #""id":"notes-app""#, with: #""id":"other-app""#)
        XCTAssertThrowsError(try AppInstallStore.requireUnchanged(inspected: shown, atCommit: swapped)) { error in
            XCTAssertEqual(error as? AppInstallStore.InstallError, .bundleChangedSinceInspection)
        }
    }
}
