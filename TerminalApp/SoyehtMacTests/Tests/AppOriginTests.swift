import Foundation
import XCTest
@testable import SoyehtMacDomain

/// The origin an app runs under must come from the installer, never from the
/// bundle. Before this suite existed, it came from `manifest.id` — a field the
/// bundle declares — so two bundles could claim one origin and, with the
/// shared website data store, one another's storage.
final class AppOriginTests: XCTestCase {
    private let manifestJSON = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme"},"capabilities":[],"optionalCapabilities":[]}"#

    private func record(installID: String, manifest: AppManifest) -> AppInstallRecord {
        AppInstallRecord(installID: installID,
                         manifest: manifest,
                         bundleRoot: URL(fileURLWithPath: "/var/empty/\(installID)"),
                         fingerprint: "fingerprint",
                         provenance: .localUnverified)
    }

    // MARK: - The defect this exists to prevent

    /// The whole point. Same declared id, two installs, two origins.
    func testTwoInstallsDeclaringTheSameIdGetDifferentOrigins() throws {
        let manifest = try AppManifest.decode(Data(manifestJSON.utf8))
        let first = record(installID: "11111111-1111-1111-1111-111111111111", manifest: manifest)
        let second = record(installID: "22222222-2222-2222-2222-222222222222", manifest: manifest)

        XCTAssertEqual(first.manifest.id, second.manifest.id,
                       "a fixture tem de partilhar a id declarada, senão o teste não exerce a colisão")
        XCTAssertNotEqual(first.origin, second.origin)
        XCTAssertNotEqual(first.origin.scheme, second.origin.scheme)
    }

    /// The converse: the declared id must not influence the origin at all, so
    /// changing it alone leaves the origin untouched.
    func testChangingOnlyTheDeclaredIdDoesNotChangeTheOrigin() throws {
        let manifest = try AppManifest.decode(Data(manifestJSON.utf8))
        let renamed = try AppManifest.decode(Data(
            manifestJSON.replacingOccurrences(of: #""id":"notes-app""#, with: #""id":"other-app""#).utf8))
        XCTAssertNotEqual(manifest.id, renamed.id, "a fixture não mutou; o teste não exerceria nada")

        let installID = "33333333-3333-3333-3333-333333333333"
        XCTAssertEqual(record(installID: installID, manifest: manifest).origin,
                       record(installID: installID, manifest: renamed).origin)
    }

    func testOriginIsDerivedFromTheInstallIdentity() {
        XCTAssertEqual(AppOrigin(installID: "abc").scheme, "soyehtapp-abc")
        XCTAssertEqual(AppOrigin.host, "local")
    }

    // MARK: - Source guard
    //
    // The checks above pin behaviour at the sites that exist. This one pins the
    // shape, because a convention never reaches the file nobody has written
    // yet: the defect was one call site handing a declared field to a producer
    // that accepted any String.

    func testTheAppSchemeHasExactlyOneProducerInProductionSource() throws {
        // Raw string on purpose: inside #"…"# the `\(` is literal, so this
        // matches the interpolation that BUILDS a scheme and not the prose
        // `soyehtapp-<installID>` written in doc comments.
        let producer = #"soyehtapp-\("#

        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 50,
                             "a varredura não encontrou fontes; um guarda que não lê nada passa sempre")

        let producers = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(producer) }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(producers, ["AppOrigin.swift"],
                       "o esquema de um app tem de ter um único produtor. Um segundo produtor é como o defeito nasceu: aceitava qualquer String e alguém passou-lhe manifest.id")
    }

    private func productionSwiftFiles() throws -> [URL] {
        let mac = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoyehtMacTests
            .deletingLastPathComponent()   // TerminalApp
            .appendingPathComponent("SoyehtMac")
        guard let walker = FileManager.default.enumerator(at: mac, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
