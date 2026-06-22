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

    func test_shadowAndV2PreviewHelpersAreReadOnly() {
        let suiteName = "ServerInventoryWriterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerStore(defaults: defaults)
        let writer = ServerInventoryWriter(store: store)
        let canonical = server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            role: "admin"
        )
        writer.upsertCanonical(canonical)
        let before = store.load()

        let report = writer.shadowCompare(
            legacyProjections: [
                ServerStoreShadowProjection(
                    server: canonical,
                    source: .sessionStorePairedServers,
                    hasCredential: true
                ),
            ],
            activeServerID: canonical.id
        )
        let envelope = writer.makeV2Envelope(installProfile: .dev)
        let rollback = writer.projectV1Servers(from: envelope)

        XCTAssertTrue(report.isClean)
        XCTAssertEqual(rollback, before)
        XCTAssertEqual(store.load(), before)
        XCTAssertNil(defaults.data(forKey: ServerStore.v2StorageKey))
    }

    func test_v2PreviewThroughFacadePreservesD2MacAndLinuxIDRules() throws {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store)
        let pairedMacID = "33333333-3333-3333-3333-333333333333"
        let canonicalShadow = server(
            id: "canonical-shadow-mac",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 4_000)
        )
        writer.upsertCanonical(canonicalShadow)
        writer.upsertCanonical(server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            role: "admin"
        ))
        writer.upsertCanonical(server(
            id: "linux-beta",
            kind: .linux,
            hostname: "linux-beta",
            lastHost: "100.64.0.10",
            role: "admin"
        ))

        let envelope = writer.makeV2Envelope(
            legacyProjections: [
                .pairedMacsStore(
                    server: server(
                        id: pairedMacID,
                        kind: .mac,
                        alias: "Alpha Mac",
                        hostname: "mac-alpha",
                        lastHost: "mac-alpha.example.test",
                        engineMachineId: "machine-alpha",
                        presencePort: 57414,
                        attachPort: 57415
                    ),
                    hasCredential: true
                ),
                ServerStoreShadowProjection(
                    server: server(
                        id: "session-mac-alpha",
                        kind: .mac,
                        hostname: "mac-alpha",
                        lastHost: "mac-alpha.example.test",
                        engineMachineId: "machine-alpha"
                    ),
                    source: .sessionStorePairedServers,
                    hasCredential: true
                ),
            ],
            installProfile: .dev
        )

        XCTAssertEqual(envelope.records.map(\.id), [
            pairedMacID,
            "linux-alpha",
            "linux-beta",
        ])
        let macRecord = try XCTUnwrap(envelope.records.first(where: { $0.id == pairedMacID }))
        XCTAssertTrue(macRecord.credentials.contains {
            $0.kind == .pairingSecret
                && $0.reference == "keychain:pairing_secret.\(pairedMacID.lowercased())"
        })
        XCTAssertTrue(macRecord.credentials.contains {
            $0.kind == .sessionToken
                && $0.reference == "keychain:server_tokens[session-mac-alpha]"
        })

        let rollback = writer.projectV1Servers(from: envelope)
        XCTAssertEqual(rollback.map(\.id), [
            pairedMacID,
            "linux-alpha",
            "linux-beta",
        ])
        XCTAssertEqual(rollback.filter { $0.kind == .linux }.map(\.lastHost), [
            "100.64.0.10",
            "100.64.0.10",
        ])
    }

    func test_serverInventoryWriterHasNoRawEnvelopeLoggingOrPersistence() throws {
        let root = try workspaceRoot()
        let source = try codeOnly(
            at: root.appendingPathComponent(
                "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift"
            )
        )

        XCTAssertFalse(source.contains("Logger("))
        XCTAssertFalse(source.contains("Telemetry"))
        XCTAssertFalse(source.contains("serverStoreV2Logger"))
        XCTAssertFalse(source.contains(".info("))
        XCTAssertFalse(source.contains(".debug("))
        XCTAssertFalse(source.contains("saveV2Envelope"))
    }

    func test_serverInventoryWriterRuntimeAdoptionIsLimitedToApprovedD5Files() throws {
        let root = try workspaceRoot()
        let allowed: Set<String> = [
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift",
            "TerminalApp/Soyeht/Server/ServerRegistry.swift",
        ]
        let offenders = try productionSwiftFiles(root: root).filter { relativePath in
            guard !allowed.contains(relativePath) else { return false }
            let source = (try? codeOnly(at: root.appendingPathComponent(relativePath))) ?? ""
            return source.contains("ServerInventoryWriter")
        }

        XCTAssertTrue(offenders.isEmpty,
            "D5 may adopt ServerInventoryWriter only inside approved inventory boundaries. Offending files: \(offenders)"
        )
    }

    func test_serverRegistryUsesWriterWithoutDirectServerStoreWritesOrV2RuntimeHelpers() throws {
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
            "shadowCompare(",
            "makeV2Envelope(",
            "projectV1Servers(",
            "loadV2Envelope(",
            "saveV2Envelope(",
        ]

        XCTAssertTrue(source.contains("ServerInventoryWriter"))
        XCTAssertTrue(source.contains("writer.upsertCanonical("))
        XCTAssertTrue(source.contains("writer.remove(id:"))
        XCTAssertTrue(source.contains("writer.migrateLegacyIfNeeded("))
        XCTAssertTrue(source.contains("writer.reconcileLegacy("))
        XCTAssertFalse(forbidden.contains { source.contains($0) },
            "ServerRegistry must use only v1 writer parity methods in D4."
        )
    }

    func test_sessionStoreUsesWriterWithoutDirectServerStoreWritesOrV2RuntimeHelpers() throws {
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
            "shadowCompare(",
            "makeV2Envelope(",
            "projectV1Servers(",
            "loadV2Envelope(",
            "saveV2Envelope(",
        ]

        XCTAssertFalse(required.contains { !source.contains($0) },
            "SessionStore must delegate v1 inventory reads/writes through ServerInventoryWriter in D5."
        )
        XCTAssertFalse(forbidden.contains { source.contains($0) },
            "SessionStore must not directly call ServerStore writes/reads or v2/shadow helpers in D5."
        )
    }

    func test_serverStoreWriteCallsStayOnKnownBoundaryFiles() throws {
        let root = try workspaceRoot()
        let allowed: Set<String> = [
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerStore.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerStoreV2.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerInventoryWriter.swift",
            "Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift",
            "TerminalApp/SoyehtMac/AppDelegate.swift",
        ]
        let writePatterns = [
            "upsertLegacyProjection(",
            ".upsert(",
            ".remove(id:",
            ".migrateLegacyIfNeeded(",
            ".reconcile(with:",
            "saveV2Envelope(",
        ]
        let offenders = try productionSwiftFiles(root: root).filter { relativePath in
            if allowed.contains(relativePath) { return false }
            let source = (try? codeOnly(at: root.appendingPathComponent(relativePath))) ?? ""
            guard source.contains("ServerStore") || source.contains("serverStore") else { return false }
            return writePatterns.contains { source.contains($0) }
        }

        XCTAssertTrue(offenders.isEmpty,
            "ServerStore write calls must stay behind known boundaries in D5. Offending files: \(offenders)"
        )
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
