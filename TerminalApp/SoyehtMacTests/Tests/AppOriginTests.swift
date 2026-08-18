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

    /// Every way of building the scheme needs the prefix as a **string
    /// literal**, so the needle is the literal *including its opening quote*.
    /// That catches interpolation, concatenation, `String(format:)` and
    /// `joined()` alike, and ignores the prose `soyehtapp-<installID>` in doc
    /// comments, which carries no quote.
    ///
    /// An earlier version searched for the interpolation `soyehtapp-\(` and
    /// therefore proved something narrower than it claimed: kairos killed it by
    /// adding a second producer built with `+`, and the guard stayed green.
    ///
    /// It still does not catch a prefix assembled from pieces
    /// (`"soyeht" + "app-"`). That is adversarial rather than accidental, and a
    /// source guard is for the refactor nobody reviewed — not for someone
    /// working around the guard on purpose.
    private static let schemeLiteral = #""soyehtapp-"#

    func testTheAppSchemeHasExactlyOneProducerInProductionSource() throws {
        let files = try productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 50,
                             "a varredura não encontrou fontes; um guarda que não lê nada passa sempre")

        let producers = try files
            .filter { try String(contentsOf: $0, encoding: .utf8).contains(Self.schemeLiteral) }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(producers, ["AppOrigin.swift"],
                       "o esquema de um app tem de ter um único produtor. Um segundo produtor é como o defeito nasceu: aceitava qualquer String e alguém passou-lhe manifest.id")
    }

    /// The guard is only worth its message if its needle catches the forms a
    /// second producer would actually take. Proving that by mutating production
    /// source costs a build per form, so the predicate is exercised directly.
    func testTheGuardsNeedleCatchesEveryFormThatBuildsAScheme() {
        let needle = Self.schemeLiteral
        // Raw strings: inside #"…"# a `\(` is literal, so these are the source
        // text a producer would have, not interpolations evaluated here.
        XCTAssertTrue(#"return "soyehtapp-\(installID)""#.contains(needle), "interpolação")
        XCTAssertTrue(##"return "soyehtapp-" + appID"##.contains(needle), "concatenação")
        XCTAssertTrue(##"String(format: "soyehtapp-%@", appID)"##.contains(needle), "formatação")
        XCTAssertTrue(##"["soyehtapp-", appID].joined()"##.contains(needle), "junção")

        XCTAssertFalse("/// served from soyehtapp-<installID>://local/".contains(needle),
                       "prosa em comentário não é um produtor e não pode disparar o guarda")
    }

    /// The app target compiles more than `SoyehtMac/`, so a producer living in
    /// the shared package would have slipped past a sweep of one directory.
    private func productionSwiftFiles() throws -> [URL] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoyehtMacTests
            .deletingLastPathComponent()   // TerminalApp
            .deletingLastPathComponent()   // <repositório>
        let roots = [
            repository.appendingPathComponent("TerminalApp/SoyehtMac"),
            repository.appendingPathComponent("Packages/SoyehtCore/Sources"),
        ]
        return roots.flatMap { root -> [URL] in
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return []
            }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
    }
}
