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

    /// The scheme prefix may appear in production source in **this one file**,
    /// and nowhere else — not in code, not in prose.
    ///
    /// Two earlier versions each promised more than they measured, and each was
    /// killed by kairos with a mutant rather than by argument:
    ///
    /// 1. Searching the interpolation `soyehtapp-\(` missed a producer built
    ///    with `+`. The suite stayed green with two live producers.
    /// 2. Searching the literal *with its opening quote* missed a producer
    ///    written as a multi-line string, where the quote is not adjacent to
    ///    the prefix. Green again.
    ///
    /// Each fix chased one more syntax, which is a losing shape: the needle has
    /// to enumerate the ways Swift can spell a literal, and Swift keeps having
    /// more. Matching the **bare prefix** stops enumerating. Any producer, in
    /// any spelling, contains it.
    ///
    /// The price is that doc comments elsewhere may not name the prefix either.
    /// That is not collateral damage, it is the same single-producer rule
    /// applied to prose: `AppOrigin` defines the scheme and everything else
    /// points at `AppOrigin`. Restating a format in prose is how the phase 2b
    /// contract kept saying `<id>` after 2a had moved to `<installID>`.
    ///
    /// One limit survives and is pinned by a test below rather than left to a
    /// reader's optimism: a prefix assembled from pieces escapes. That is
    /// someone working around the guard, not the refactor nobody reviewed.
    private static let schemePrefix = "soyehtapp-"

    private static let sweptRoots = ["TerminalApp/SoyehtMac", "Packages/SoyehtCore/Sources"]

    func testTheAppSchemeHasExactlyOneProducerInProductionSource() throws {
        var producers: [String] = []

        for root in Self.sweptRoots {
            let files = try swiftFiles(under: root)
            // Per root, deliberately. Aggregated, a root that stops resolving
            // returns [] and vanishes into the other root's total: the guard
            // stays green while sweeping half of what its message promises.
            XCTAssertGreaterThan(files.count, 50,
                                 "a raiz \(root) não devolveu fontes; um guarda que não lê nada passa sempre")
            producers += try files
                .filter { try String(contentsOf: $0, encoding: .utf8).contains(Self.schemePrefix) }
                .map(\.lastPathComponent)
        }

        XCTAssertEqual(producers.sorted(), ["AppOrigin.swift"],
                       "o esquema de um app tem de ter um único produtor, e um único sítio que o nomeie. Um segundo produtor é como o defeito nasceu: aceitava qualquer String e alguém passou-lhe manifest.id")
    }

    /// Proving the needle by mutating production source costs a build per form,
    /// so the predicate is exercised directly — including the limit it does NOT
    /// cover, so that limit is a failing expectation someone can read rather
    /// than a sentence someone can skip.
    func testTheGuardsNeedleCatchesEveryFormThatBuildsAScheme() {
        let needle = Self.schemePrefix
        // Raw strings: inside #"…"# a `\(` is literal, so these are the source
        // text a producer would have, not interpolations evaluated here.
        XCTAssertTrue(#"return "soyehtapp-\(installID)""#.contains(needle), "interpolação")
        XCTAssertTrue(##"return "soyehtapp-" + appID"##.contains(needle), "concatenação")
        XCTAssertTrue(##"String(format: "soyehtapp-%@", appID)"##.contains(needle), "formatação")
        XCTAssertTrue(##"["soyehtapp-", appID].joined()"##.contains(needle), "junção")
        XCTAssertTrue("\"\"\"\n    soyehtapp-\\(appID)\n    \"\"\"".contains(needle), "string multilinha")
        XCTAssertTrue("/// served from soyehtapp-<installID>://local/".contains(needle), "prosa")

        XCTAssertFalse(##"return "soyeht" + "app-" + appID"##.contains(needle),
                       "limite conhecido: prefixo montado aos bocados escapa. Esta assercão existe para o limite ser visível, não para ser aceitável")
    }

    /// The app target compiles more than `SoyehtMac/`, so a producer living in
    /// the shared package would have slipped past a sweep of one directory.
    private func swiftFiles(under relativePath: String) throws -> [URL] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoyehtMacTests
            .deletingLastPathComponent()   // TerminalApp
            .deletingLastPathComponent()   // <repositório>
        let root = repository.appendingPathComponent(relativePath)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
