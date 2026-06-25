import XCTest
@testable import SoyehtCore

final class ServerInventoryWriterTests: XCTestCase {
    func test_v1CRUDParityMatchesServerStore() {
        let (directStore, directTeardown) = makeStore()
        defer { directTeardown() }
        let (writerStore, writerTeardown) = makeStore()
        defer { writerTeardown() }
        let writer = ServerInventoryWriter(store: writerStore)

        let original = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha"
        )
        var updated = original
        updated.alias = "Alpha Mac"

        XCTAssertEqual(directStore.upsert(original), writer.upsertCanonical(original))
        XCTAssertEqual(directStore.upsert(updated), writer.upsertCanonical(updated))
        XCTAssertEqual(directStore.remove(id: original.id), writer.remove(id: original.id))
        XCTAssertEqual(directStore.load(), writer.load())
    }

    func test_legacyProjectionMigrationAndReconcileParityMatchServerStore() {
        let seed = [
            server(
                id: "22222222-2222-2222-2222-222222222222",
                kind: .mac,
                hostname: "mac-alpha",
                lastHost: "mac-alpha.example.test",
                engineMachineId: "machine-alpha"
            ),
            server(
                id: "legacy-mac-alpha",
                kind: .mac,
                alias: "Alpha Mac",
                hostname: "mac-alpha",
                lastHost: "mac-alpha.example.test",
                engineMachineId: "machine-alpha",
                lastSeenAt: Date(timeIntervalSince1970: 2_000)
            ),
            server(
                id: "linux-alpha",
                kind: .linux,
                hostname: "linux-alpha",
                lastHost: "100.64.0.10",
                role: "admin"
            ),
        ]

        let (directMigrationStore, directMigrationTeardown) = makeStore()
        defer { directMigrationTeardown() }
        let (writerMigrationStore, writerMigrationTeardown) = makeStore()
        defer { writerMigrationTeardown() }
        let migrationWriter = ServerInventoryWriter(store: writerMigrationStore)

        directMigrationStore.migrateLegacyIfNeeded(
            seed: seed,
            secretOwnedIDs: ["22222222-2222-2222-2222-222222222222"]
        )
        migrationWriter.migrateLegacyIfNeeded(
            seed: seed,
            secretOwnedIDs: ["22222222-2222-2222-2222-222222222222"]
        )
        XCTAssertEqual(sorted(directMigrationStore.load()), sorted(migrationWriter.load()))

        let (directReconcileStore, directReconcileTeardown) = makeStore()
        defer { directReconcileTeardown() }
        let (writerReconcileStore, writerReconcileTeardown) = makeStore()
        defer { writerReconcileTeardown() }
        let reconcileWriter = ServerInventoryWriter(store: writerReconcileStore)

        let directReconciled = directReconcileStore.reconcile(
            with: seed,
            secretOwnedIDs: ["22222222-2222-2222-2222-222222222222"]
        )
        let writerReconciled = reconcileWriter.reconcileLegacy(
            seed: seed,
            secretOwnedIDs: ["22222222-2222-2222-2222-222222222222"]
        )
        XCTAssertEqual(sorted(directReconciled), sorted(writerReconciled))
        XCTAssertEqual(sorted(directReconcileStore.load()), sorted(writerReconcileStore.load()))
    }

    func test_upsertLegacyProjectionParityMatchesServerStore() {
        let (directStore, directTeardown) = makeStore()
        defer { directTeardown() }
        let (writerStore, writerTeardown) = makeStore()
        defer { writerTeardown() }
        let writer = ServerInventoryWriter(store: writerStore)
        let canonical = server(
            id: "linux-alpha",
            kind: .linux,
            alias: "Canonical Linux",
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            role: "admin",
            lastSeenAt: Date(timeIntervalSince1970: 2_000)
        )
        let legacyProjection = server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha-renamed",
            lastHost: "100.64.0.11",
            role: "admin",
            lastSeenAt: Date(timeIntervalSince1970: 1_500)
        )

        directStore.upsert(canonical)
        writer.upsertCanonical(canonical)

        XCTAssertEqual(
            directStore.upsertLegacyProjection(legacyProjection),
            writer.upsertLegacyProjection(legacyProjection)
        )
        XCTAssertEqual(directStore.load(), writer.load())
    }

    func test_serverInventoryWriterHasNoLoggingOrRetiredV2Runtime() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent(
                "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift"
            )
        )

        XCTAssertFalse(source.contains("Logger("))
        XCTAssertFalse(source.contains("Telemetry"))
        XCTAssertFalse(source.contains(".info("))
        XCTAssertFalse(source.contains(".debug("))
        XCTAssertFalse(retiredInventoryTokens.contains { source.contains($0) },
            "ServerInventoryWriter must remain a v1 facade after retiring the inert path.")
    }

    func test_retiredV2RuntimeSymbolsAreAbsentFromProductionSources() throws {
        let root = try workspaceRoot()
        let offenders = try productionSwiftFiles(root: root).compactMap { relativePath -> String? in
            let source = (try? codeOnly(at: root.appendingPathComponent(relativePath))) ?? ""
            let matches = retiredInventoryTokens.filter { source.contains($0) }
            return matches.isEmpty ? nil : "\(relativePath): \(matches.joined(separator: ", "))"
        }

        XCTAssertTrue(offenders.isEmpty,
            "Retired inventory symbols must not remain in production sources: \(offenders)"
        )
    }

    func test_serverInventoryWriterRuntimeAdoptionIsLimitedToApprovedV1Files() throws {
        let root = try workspaceRoot()
        let allowed: Set<String> = [
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift",
            "TerminalApp/SoyehtMac/AppDelegate.swift",
            "TerminalApp/Soyeht/Server/ServerRegistry.swift",
        ]
        let offenders = try productionSwiftFiles(root: root).filter { relativePath in
            guard !allowed.contains(relativePath) else { return false }
            let source = (try? codeOnly(at: root.appendingPathComponent(relativePath))) ?? ""
            return source.contains("ServerInventoryWriter")
        }

        XCTAssertTrue(offenders.isEmpty,
            "ServerInventoryWriter adoption must stay inside approved v1 inventory boundaries. Offending files: \(offenders)"
        )
    }

    func test_serverRegistryUsesWriterWithoutDirectServerStoreWrites() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent("TerminalApp/Soyeht/Server/ServerRegistry.swift")
        )
        let forbidden = [
            "ServerStore(",
            "store.upsert(",
            "store.remove(id:",
            "store.migrateLegacyIfNeeded(",
            "store.reconcile(with:",
            "save(",
        ]

        XCTAssertTrue(source.contains("ServerInventoryWriter"))
        XCTAssertTrue(source.contains("writer.upsertCanonical("))
        XCTAssertTrue(source.contains("writer.remove(id:"))
        XCTAssertTrue(source.contains("writer.migrateLegacyIfNeeded("))
        XCTAssertTrue(source.contains("writer.reconcileLegacy("))
        XCTAssertFalse(forbidden.contains { source.contains($0) },
            "ServerRegistry must mutate inventory only through the v1 writer facade.")
    }

    func test_serverRegistryReadsFromV1WriterAuthority() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent("TerminalApp/Soyeht/Server/ServerRegistry.swift")
        )

        XCTAssertTrue(source.contains("self.servers = self.writer.load()"))
        XCTAssertTrue(source.contains("let next = writer.load()"))
        XCTAssertFalse(retiredInventoryTokens.contains { source.contains($0) })
    }

    func test_serverRegistryWiresLiveCredentialRekeyer() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent("TerminalApp/Soyeht/Server/ServerRegistry.swift")
        )
        let tokenWirings = source.components(
            separatedBy: "tokenOwnedIDs: SessionStore.shared.serverTokenOwnerIDs()"
        ).count - 1
        let rekeyerWirings = source.components(
            separatedBy: "credentialRekeyer: Self.sessionTokenRekeyer"
        ).count - 1

        XCTAssertEqual(tokenWirings, 2,
            "ServerRegistry must pass live tokenOwnedIDs at BOTH migrateLegacyIfNeeded and reconcileLegacy.")
        XCTAssertEqual(rekeyerWirings, 2,
            "ServerRegistry must pass the credential rekeyer at BOTH migrate and reconcile sites.")
        XCTAssertTrue(
            source.contains("SessionStore.shared.copyServerTokenIfMissing(from: loserID, to: winnerID)"),
            "sessionTokenRekeyer must call the live SessionStore.copyServerTokenIfMissing(from:to:)."
        )
    }

    func test_sessionStoreUsesWriterWithoutDirectServerStoreWrites() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift")
        )
        let required = [
            "private let inventoryWriter: ServerInventoryWriter",
            "ServerInventoryWriter(store:",
            "inventoryWriter.upsertLegacyProjection(",
            "inventoryWriter.remove(id:",
            "inventoryWriter.load()",
        ]
        let forbidden = [
            "serverStore.upsertLegacyProjection(",
            "serverStore.remove(id:",
            "serverStore.load(",
            "serverStore.upsert(",
            "serverStore.migrateLegacyIfNeeded(",
            "serverStore.reconcile(with:",
        ]

        XCTAssertFalse(required.contains { !source.contains($0) },
            "SessionStore must delegate v1 inventory reads/writes through ServerInventoryWriter.")
        XCTAssertFalse(forbidden.contains { source.contains($0) },
            "SessionStore must not directly call ServerStore writes/reads.")
        XCTAssertFalse(retiredInventoryTokens.contains { source.contains($0) })
    }

    func test_sessionStoreCanonicalReadsRemainV1WriterAuthority() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift")
        )

        XCTAssertTrue(
            source.contains(
                """
                    public func canonicalServers() -> [Server] {
                        inventoryWriter.load()
                    }
                """
            ),
            "SessionStore.canonicalServers() should remain on the shipped v1 writer authority."
        )
        XCTAssertTrue(source.contains("public func credentialedCanonicalServers() -> [PairedServer] {"))
        XCTAssertTrue(source.contains("canonicalServers().compactMap { canonicalServer in"))
        XCTAssertFalse(retiredInventoryTokens.contains { source.contains($0) })
    }

    func test_macOSInventoryReadersStayOnSessionStoreV1Facade() throws {
        let root = try workspaceRoot()
        let expectedV1Readers: [String: String] = [
            "TerminalApp/SoyehtMac/Servers/ConnectedServersWindowController.swift":
                "store.credentialedCanonicalServers().sorted",
            "TerminalApp/SoyehtMac/InstancePicker/InstancePickerViewController.swift":
                "serverChoices = store.credentialedCanonicalServers()",
            "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/MacActiveServerContextResolver.swift":
                "sessionStore.canonicalServers().first(where: { $0.id == activeID })",
            "TerminalApp/SoyehtMac/AppDelegate.swift":
                "SessionStore.shared.credentialedCanonicalServers()",
        ]

        for (relativePath, expectedSnippet) in expectedV1Readers {
            let source = try codeOnly(at: root.appendingPathComponent(relativePath))
            XCTAssertTrue(source.contains(expectedSnippet), "\(relativePath) should keep reading through the SessionStore v1 facade.")
        }
    }

    func test_macOSStartupMigrationUsesWriterWithoutDirectServerStoreWrites() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent("TerminalApp/SoyehtMac/AppDelegate.swift")
        )
        let forbidden = [
            "ServerStore().migrateLegacyIfNeeded(",
            "ServerStore().reconcile(",
            "ServerStore().upsert(",
            "ServerStore().remove(id:",
        ]

        XCTAssertTrue(source.contains("ServerInventoryWriter().migrateLegacyIfNeeded("))
        XCTAssertFalse(forbidden.contains { source.contains($0) },
            "macOS startup migration must use only the writer v1 migration parity method.")
    }

    func test_serverStoreWriteCallsStayOnKnownBoundaryFiles() throws {
        let root = try workspaceRoot()
        let allowed: Set<String> = [
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerStore.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift",
            "TerminalApp/Soyeht/Server/ServerRegistry.swift",
        ]
        let writePatterns = [
            "upsertLegacyProjection(",
            ".upsert(",
            ".remove(id:",
            ".migrateLegacyIfNeeded(",
            ".reconcile(with:",
        ]
        let offenders = try productionSwiftFiles(root: root).filter { relativePath in
            if allowed.contains(relativePath) { return false }
            let source = (try? codeOnly(at: root.appendingPathComponent(relativePath))) ?? ""
            guard source.contains("ServerStore") || source.contains("serverStore") else { return false }
            return writePatterns.contains { source.contains($0) }
        }

        XCTAssertTrue(offenders.isEmpty,
            "ServerStore write calls must stay behind known boundaries. Offending files: \(offenders)"
        )
    }

    func test_adHocServerStoreLoadReadsAreConfinedToAllowlist() throws {
        let root = try workspaceRoot()
        let allowed: Set<String> = [
            // SoyehtCore-level default fallback for an injected provider; iOS UI
            // should pass a ServerRegistry-backed provider. Tracked in
            // docs/server-model.md as a read-side follow-up.
            "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawDetailViewModel.swift",
        ]
        let offenders = try productionSwiftFiles(root: root).filter { relativePath in
            guard !allowed.contains(relativePath) else { return false }
            let source = (try? codeOnly(at: root.appendingPathComponent(relativePath))) ?? ""
            return source.contains("ServerStore().load()")
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Ad-hoc `ServerStore().load()` reads bypass the in-memory inventory \
            authority (ServerRegistry) and can disagree with it mid-mutation. Read \
            through the authority, or inject a provider. Offending files: \(offenders)
            """
        )
    }

    private var retiredInventoryTokens: [String] {
        [
            "ServerStoreV2",
            "ServerStoreShadowComparer",
            "ServerStoreShadowProjection",
            "v2ReadEnabledKey",
            "loadCanonical",
            "saveV2Envelope",
            "loadV2Envelope",
            "migrationDryRunReadiness",
            "mirrorToV2",
        ]
    }

    private func makeStore() -> (ServerStore, () -> Void) {
        let suiteName = "com.soyeht.tests.serverinventory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ServerStore(defaults: defaults)
        let teardown = { defaults.removePersistentDomain(forName: suiteName) }
        return (store, teardown)
    }

    private func server(
        id: String,
        kind: Server.Kind,
        alias: String? = nil,
        hostname: String,
        lastHost: String?,
        engineMachineId: String? = nil,
        apiEndpoint: URL? = nil,
        bootstrapEndpoint: URL? = nil,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        role: String? = nil,
        sessionExpiresAt: String? = nil,
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_100)
    ) -> Server {
        Server(
            id: id,
            kind: kind,
            pairedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: lastSeenAt,
            alias: alias,
            hostname: hostname,
            lastHost: lastHost,
            engineMachineId: engineMachineId,
            theyOS: TheyOSSnapshot(),
            apiEndpoint: apiEndpoint,
            bootstrapEndpoint: bootstrapEndpoint,
            presencePort: presencePort,
            attachPort: attachPort,
            role: role,
            sessionExpiresAt: sessionExpiresAt
        )
    }

    private func sorted(_ servers: [Server]) -> [Server] {
        servers.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func workspaceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func productionSwiftFiles(root: URL) throws -> [String] {
        let roots = [
            "Packages/SoyehtCore/Sources",
            "TerminalApp/Soyeht",
            "TerminalApp/SoyehtMac",
        ]
        let rootPath = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        var files: [String] = []
        for relativeRoot in roots {
            let url = root.appendingPathComponent(relativeRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                files.append(String(fileURL.path.dropFirst(rootPath.count)))
            }
        }
        return files.sorted()
    }

    private func codeOnly(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
