import XCTest
@testable import SoyehtCore

final class ServerStoreShadowComparerTests: XCTestCase {
    func test_macOnlyProjection_matchesWithoutMismatches() {
        let mac = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            presencePort: 57414,
            attachPort: 57415
        )

        let report = ServerStoreShadowComparer.compare(
            canonicalServers: [mac],
            legacyProjections: [
                projection(mac, source: .pairedMacsStore, hasCredential: true),
            ],
            activeServerID: mac.id
        )

        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.canonicalCount, 1)
        XCTAssertEqual(report.legacyProjectionCount, 1)
        XCTAssertEqual(report.collapsedLegacyProjectionCount, 1)
        XCTAssertEqual(report.credentialedProjectionCount, 1)
    }

    func test_linuxAdminHostProjection_matchesWithoutMismatches() {
        let linux = server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            apiEndpoint: URL(string: "https://linux-alpha.example.test:8892")!,
            role: "admin"
        )

        let report = ServerStoreShadowComparer.compare(
            canonicalServers: [linux],
            legacyProjections: [
                projection(linux, source: .sessionStorePairedServers, hasCredential: true),
            ]
        )

        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.canonicalCount, 1)
        XCTAssertEqual(report.legacyProjectionCount, 1)
        XCTAssertEqual(report.collapsedLegacyProjectionCount, 1)
        XCTAssertEqual(report.credentialedProjectionCount, 1)
    }

    func test_projectionFactoriesPinLegacySourceAndCredentialPresenceOnly() {
        let mac = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha"
        )
        let pairedServer = PairedServer(
            id: "linux-alpha",
            host: "100.64.0.10",
            name: "linux-alpha",
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )

        let macProjection = ServerStoreShadowProjection.pairedMacsStore(
            server: mac,
            hasCredential: false
        )
        let sessionProjection = ServerStoreShadowProjection.sessionStorePairedServer(
            pairedServer,
            hasCredential: true
        )

        XCTAssertEqual(macProjection.source, .pairedMacsStore)
        XCTAssertFalse(macProjection.hasCredential)
        XCTAssertEqual(macProjection.server.kind, .mac)
        XCTAssertEqual(sessionProjection.source, .sessionStorePairedServers)
        XCTAssertTrue(sessionProjection.hasCredential)
        XCTAssertEqual(sessionProjection.server.kind, .linux)
        XCTAssertEqual(sessionProjection.server.role, "admin")
    }

    func test_duplicateMacProjection_collapsesByMachineIdentityAndPreservesStableID() {
        let canonical = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_100)
        )
        let legacyUUID = server(
            id: canonical.id,
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000)
        )
        let legacyQR = server(
            id: "legacy-mac-alpha",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_200)
        )

        let report = ServerStoreShadowComparer.compare(
            canonicalServers: [canonical],
            legacyProjections: [
                projection(legacyUUID, source: .pairedMacsStore, hasCredential: true),
                projection(legacyQR, source: .sessionStorePairedServers, hasCredential: false),
            ]
        )

        XCTAssertEqual(report.count(for: .duplicateLegacyProjection), 1)
        XCTAssertEqual(report.count(for: .missingCanonicalRecord), 0)
        XCTAssertEqual(report.count(for: .missingLegacyProjection), 0)
        XCTAssertEqual(report.collapsedLegacyProjectionCount, 1)
        XCTAssertEqual(report.credentialedProjectionCount, 1)
    }

    func test_missingCredentialReportsTokenOnlyAsCategoryCounts() {
        let linux = server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            role: "admin"
        )

        let report = ServerStoreShadowComparer.compare(
            canonicalServers: [linux],
            legacyProjections: [
                projection(linux, source: .sessionStorePairedServers, hasCredential: false),
            ],
            activeServerID: linux.id
        )

        XCTAssertEqual(report.count(for: .missingCredential), 1)
        XCTAssertEqual(report.count(for: .activeIDMissingCredential), 1)
        XCTAssertEqual(report.credentialedProjectionCount, 0)
        XCTAssertEqual(report.mismatches.map(\.category).sorted { $0.rawValue < $1.rawValue }, [
            .activeIDMissingCredential,
            .missingCredential,
        ])
    }

    func test_staleAliasAndHostnameReportNeutralCategoriesOnly() {
        let canonical = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            alias: "Primary Mac",
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha"
        )
        let legacy = server(
            id: canonical.id,
            kind: .mac,
            alias: "Stale Mac",
            hostname: "mac-alpha-old",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha"
        )

        let report = ServerStoreShadowComparer.compare(
            canonicalServers: [canonical],
            legacyProjections: [
                projection(legacy, source: .pairedMacsStore, hasCredential: true),
            ]
        )

        XCTAssertEqual(report.count(for: .displayNameMismatch), 1)
        XCTAssertEqual(report.count(for: .hostnameMismatch), 1)
        XCTAssertEqual(report.count(for: .endpointMismatch), 0)
    }

    func test_activeIDMismatchReportsBothMissingSidesWithoutIdentifiers() {
        let mac = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha"
        )

        let report = ServerStoreShadowComparer.compare(
            canonicalServers: [mac],
            legacyProjections: [
                projection(mac, source: .pairedMacsStore, hasCredential: true),
            ],
            activeServerID: "missing-active"
        )

        XCTAssertEqual(report.count(for: .activeIDMissingCanonical), 1)
        XCTAssertEqual(report.count(for: .activeIDMissingLegacy), 1)
        XCTAssertFalse(report.mismatches.contains(where: { $0.category == .missingCanonicalRecord }))
        XCTAssertFalse(report.mismatches.contains(where: { $0.category == .missingLegacyProjection }))
    }

    func test_compareIsIdempotentForStableInputs() {
        let canonicalMac = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_100)
        )
        let duplicateMac = server(
            id: "legacy-mac-alpha",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_200)
        )
        let canonicalLinux = server(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            role: "admin"
        )

        let projections = [
            projection(duplicateMac, source: .sessionStorePairedServers, hasCredential: false),
            projection(canonicalLinux, source: .sessionStorePairedServers, hasCredential: true),
            projection(canonicalMac, source: .pairedMacsStore, hasCredential: true),
        ]

        let first = ServerStoreShadowComparer.compare(
            canonicalServers: [canonicalLinux, canonicalMac],
            legacyProjections: projections,
            activeServerID: canonicalMac.id
        )
        let second = ServerStoreShadowComparer.compare(
            canonicalServers: [canonicalLinux, canonicalMac],
            legacyProjections: projections,
            activeServerID: canonicalMac.id
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count(for: .duplicateLegacyProjection), 1)
    }

    private func projection(
        _ server: Server,
        source: ServerStoreShadowProjection.Source,
        hasCredential: Bool
    ) -> ServerStoreShadowProjection {
        ServerStoreShadowProjection(server: server, source: source, hasCredential: hasCredential)
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
            apiEndpoint: apiEndpoint,
            bootstrapEndpoint: bootstrapEndpoint,
            presencePort: presencePort,
            attachPort: attachPort,
            role: role,
            sessionExpiresAt: nil
        )
    }
}
