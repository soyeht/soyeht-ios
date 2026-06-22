import XCTest
@testable import SoyehtCore

final class ServerStoreV2MigratorTests: XCTestCase {
    func test_migratorPreservesPairedMacSecretOwningIDByteForByte() throws {
        let pairedMacID = "AAAAAAAA-0000-0000-0000-000000000001"
        let canonical = server(
            id: "canonical-shadow-mac",
            kind: .mac,
            alias: nil,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 3_000)
        )
        let pairedMac = server(
            id: pairedMacID,
            kind: .mac,
            alias: "Alpha Mac",
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            presencePort: 57414,
            attachPort: 57415,
            lastSeenAt: Date(timeIntervalSince1970: 1_000)
        )
        let sessionMac = server(
            id: "session-mac-alpha",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 4_000)
        )

        let envelope = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: [canonical],
            legacyProjections: [
                .pairedMacsStore(server: pairedMac, hasCredential: true),
                ServerStoreShadowProjection(
                    server: sessionMac,
                    source: .sessionStorePairedServers,
                    hasCredential: true
                ),
            ],
            installProfile: .dev
        )

        let record = try XCTUnwrap(envelope.records.first)
        XCTAssertEqual(envelope.records.count, 1)
        XCTAssertEqual(record.id, pairedMacID)
        XCTAssertEqual(record.display.alias, "Alpha Mac")
        XCTAssertEqual(record.v1Projection.presencePort, 57414)
        XCTAssertEqual(record.v1Projection.attachPort, 57415)
        XCTAssertTrue(record.credentials.contains {
            $0.kind == .pairingSecret
                && $0.reference == "keychain:pairing_secret.\(pairedMacID.lowercased())"
        })
        XCTAssertTrue(record.credentials.contains {
            $0.kind == .sessionToken
                && $0.reference == "keychain:server_tokens[session-mac-alpha]"
        })
        XCTAssertTrue(record.legacyProvenance.contains {
            $0.source == .pairedMacsStore && $0.legacyID == pairedMacID
        })
        XCTAssertTrue(record.legacyProvenance.contains {
            $0.source == .sessionStorePairedServers && $0.legacyID == "session-mac-alpha"
        })
        XCTAssertTrue(record.legacyProvenance.contains {
            $0.source == .serverStoreV1 && $0.legacyID == "canonical-shadow-mac"
        })

        let rollback = ServerStoreV2Migrator.projectV1Servers(from: envelope)
        XCTAssertEqual(rollback.map(\.id), [pairedMacID])
        XCTAssertEqual(rollback.first?.presencePort, 57414)
        XCTAssertEqual(rollback.first?.attachPort, 57415)
    }

    func test_linuxAdminHostsPreservePairedServerIDsAndDoNotDedupeByHost() {
        let linuxAlpha = pairedServer(
            id: "linux-alpha",
            host: "100.64.0.10",
            name: "linux-alpha"
        )
        let linuxBeta = pairedServer(
            id: "linux-beta",
            host: "100.64.0.10",
            name: "linux-beta"
        )

        let envelope = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: [],
            legacyProjections: [
                .sessionStorePairedServer(linuxAlpha, hasCredential: true),
                .sessionStorePairedServer(linuxBeta, hasCredential: true),
            ],
            installProfile: .dev
        )

        XCTAssertEqual(envelope.records.map(\.id), ["linux-alpha", "linux-beta"])
        XCTAssertEqual(envelope.records.map(\.kind), [.linux, .linux])
        XCTAssertTrue(envelope.records.allSatisfy { record in
            record.credentials.contains {
                $0.kind == .sessionToken
                    && $0.reference == "keychain:server_tokens[\(record.id)]"
            }
        })

        let rollback = ServerStoreV2Migrator.projectV1Servers(from: envelope)
        XCTAssertEqual(rollback.map(\.id), ["linux-alpha", "linux-beta"])
        XCTAssertEqual(rollback.map(\.lastHost), ["100.64.0.10", "100.64.0.10"])
        XCTAssertEqual(rollback.map(\.role), ["admin", "admin"])
    }

    func test_duplicateMacCollapseIsDeterministicAcrossInputOrdering() throws {
        let pairedMac = server(
            id: "BBBBBBBB-0000-0000-0000-000000000001",
            kind: .mac,
            alias: "Alpha Mac",
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            presencePort: 57414,
            lastSeenAt: Date(timeIntervalSince1970: 2_000)
        )
        let canonical = server(
            id: "canonical-alpha",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 4_000)
        )
        let session = server(
            id: "session-alpha",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 3_000)
        )

        let first = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: [canonical],
            legacyProjections: [
                .pairedMacsStore(server: pairedMac, hasCredential: false),
                ServerStoreShadowProjection(server: session, source: .sessionStorePairedServers, hasCredential: true),
            ],
            installProfile: .dev
        )
        let second = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: [canonical],
            legacyProjections: [
                ServerStoreShadowProjection(server: session, source: .sessionStorePairedServers, hasCredential: true),
                .pairedMacsStore(server: pairedMac, hasCredential: false),
            ],
            installProfile: .dev
        )

        XCTAssertEqual(first.records.map(\.id), ["BBBBBBBB-0000-0000-0000-000000000001"])
        XCTAssertEqual(try encodedString(first), try encodedString(second))
    }

    func test_v1RollbackProjectionRoundTripsKnownServerFields() {
        var mac = server(
            id: "CCCCCCCC-0000-0000-0000-000000000001",
            kind: .mac,
            alias: "Primary Mac",
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            apiEndpoint: URL(string: "https://mac-alpha.example.test:8892")!,
            bootstrapEndpoint: URL(string: "http://mac-alpha.example.test:8101")!,
            presencePort: 57414,
            attachPort: 57415
        )
        mac.theyOS = TheyOSSnapshot(
            status: .running,
            version: "0.1.21",
            lastCheckedAt: Date(timeIntervalSince1970: 2_500)
        )
        let linux = server(
            id: "linux-alpha",
            kind: .linux,
            alias: nil,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            apiEndpoint: URL(string: "https://linux-alpha.example.test:8892")!,
            bootstrapEndpoint: URL(string: "http://100.64.0.10:8101")!,
            role: "admin",
            sessionExpiresAt: "2026-12-31T00:00:00Z"
        )

        let envelope = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: [linux, mac],
            installProfile: .dev
        )
        let rollback = ServerStoreV2Migrator.projectV1Servers(from: envelope)

        XCTAssertEqual(rollback, sorted([mac, linux]))
    }

    func test_unknownFutureKindIsPreservedInEnvelopeAndSkippedByV1Rollback() throws {
        let known = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: [
                server(
                    id: "linux-alpha",
                    kind: .linux,
                    hostname: "linux-alpha",
                    lastHost: "100.64.0.10",
                    role: "admin"
                ),
            ],
            installProfile: .dev
        ).records
        let future = ServerStoreV2Record(
            id: "future-alpha",
            kind: .unknown("futureOS"),
            display: ServerStoreV2Display(hostname: "future-alpha"),
            pairedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_100)
        )
        let envelope = ServerStoreV2Envelope(records: known + [future])

        let reencoded = try ServerStoreV2Coding.encoder().encode(envelope)
        let decoded = try ServerStoreV2Coding.decoder().decode(ServerStoreV2Envelope.self, from: reencoded)
        let rollback = ServerStoreV2Migrator.projectV1Servers(from: decoded)

        XCTAssertTrue(decoded.records.contains { $0.id == "future-alpha" && $0.kind.rawValue == "futureOS" })
        XCTAssertEqual(rollback.map(\.id), ["linux-alpha"])
    }

    func test_migratorIsPureAndDoesNotWriteV1OrV2Storage() {
        let suiteName = "ServerStoreV2MigratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerStore(defaults: defaults)
        let canonical = server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            role: "admin"
        )
        store.save([canonical])

        _ = ServerStoreV2Migrator.makeEnvelope(
            canonicalServers: store.load(),
            installProfile: .dev
        )

        XCTAssertEqual(store.load(), [canonical])
        XCTAssertNil(defaults.data(forKey: ServerStore.v2StorageKey))
    }

    func test_migratorSourceDoesNotLogOrEmitRawEnvelope() throws {
        let root = try workspaceRoot()
        let sourceURL = root.appendingPathComponent(
            "Packages/SoyehtCore/Sources/SoyehtCore/Server/ServerStoreV2Migrator.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let codeOnly = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(codeOnly.contains("Logger("))
        XCTAssertFalse(codeOnly.contains("Telemetry"))
        XCTAssertFalse(codeOnly.contains("serverStoreV2Logger"))
        XCTAssertFalse(codeOnly.contains(".info("))
        XCTAssertFalse(codeOnly.contains(".debug("))
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

    private func pairedServer(id: String, host: String, name: String) -> PairedServer {
        PairedServer(
            id: id,
            host: host,
            name: name,
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )
    }

    private func sorted(_ servers: [Server]) -> [Server] {
        servers.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func encodedString(_ envelope: ServerStoreV2Envelope) throws -> String {
        let data = try ServerStoreV2Coding.encoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private func workspaceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
