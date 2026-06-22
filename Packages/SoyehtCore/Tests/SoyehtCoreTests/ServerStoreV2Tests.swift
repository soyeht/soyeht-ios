import XCTest
@testable import SoyehtCore

final class ServerStoreV2Tests: XCTestCase {
    func test_envelopeEncodeDecode_isDeterministicAndSorted() throws {
        let linux = record(
            id: "linux-alpha",
            kind: .linux,
            hostname: "linux-alpha",
            lastHost: "100.64.0.10",
            credentials: [
                ServerStoreV2CredentialReference(kind: .sessionToken, reference: "keychain:server-token:linux-alpha"),
            ],
            legacyProvenance: [
                ServerStoreV2LegacyProvenance(source: .sessionStorePairedServers, legacyID: "linux-alpha"),
            ]
        )
        let mac = record(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            credentials: [
                ServerStoreV2CredentialReference(kind: .pairingSecret, reference: "keychain:pairing-secret:mac-alpha"),
            ],
            legacyProvenance: [
                ServerStoreV2LegacyProvenance(source: .pairedMacsStore, legacyID: "11111111-1111-1111-1111-111111111111"),
            ]
        )
        let envelope = ServerStoreV2Envelope(records: [linux, mac])

        let encodedA = try ServerStoreV2Coding.encoder().encode(envelope)
        let encodedB = try ServerStoreV2Coding.encoder().encode(envelope)
        XCTAssertEqual(encodedA, encodedB)

        let decoded = try ServerStoreV2Coding.decoder().decode(ServerStoreV2Envelope.self, from: encodedA)
        let reencoded = try ServerStoreV2Coding.encoder().encode(decoded)
        XCTAssertEqual(encodedA, reencoded)
        XCTAssertEqual(decoded.records.map(\.id), [
            "11111111-1111-1111-1111-111111111111",
            "linux-alpha",
        ])
    }

    func test_recordProjection_preservesMacEndpointCandidatesFromEndpointPolicy() throws {
        let server = server(
            id: "11111111-1111-1111-1111-111111111111",
            kind: .mac,
            hostname: "mac-alpha",
            lastHost: "mac-alpha.example.test",
            engineMachineId: "machine-alpha",
            apiEndpoint: URL(string: "https://mac-alpha.example.test:8892")!,
            presencePort: 57414,
            attachPort: 57415
        )

        let record = ServerStoreV2Record(
            server: server,
            credentials: [
                ServerStoreV2CredentialReference(kind: .pairingSecret, reference: "keychain:pairing-secret:mac-alpha"),
            ],
            legacyProvenance: [
                ServerStoreV2LegacyProvenance(source: .serverStoreV1, legacyID: server.id),
            ],
            installProfile: .dev
        )

        XCTAssertEqual(record.id, server.id)
        XCTAssertEqual(record.kind, .mac)
        XCTAssertEqual(record.machine.engineMachineId, "machine-alpha")
        XCTAssertTrue(record.endpoints.contains(where: { $0.purpose == .adminAPI && $0.source == .canonical }))
        XCTAssertTrue(record.endpoints.contains(where: { $0.purpose == .bootstrapStatus && $0.source == .endpointPolicy }))
        XCTAssertTrue(record.endpoints.contains(where: { $0.purpose == .presence && $0.url.scheme == "ws" }))
        XCTAssertTrue(record.endpoints.contains(where: { $0.purpose == .paneAttach && $0.url.scheme == "ws" }))
    }

    func test_unknownFutureKind_isPreservedAcrossDecodeEncode() throws {
        let json = """
        {
          "schemaVersion": 2,
          "records": [
            {
              "id": "future-alpha",
              "kind": "futureOS",
              "display": { "hostname": "future-alpha" },
              "pairedAt": 1000,
              "lastSeenAt": 1001
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try ServerStoreV2Coding.decoder().decode(ServerStoreV2Envelope.self, from: json)
        guard case .unknown("futureOS") = envelope.records.first?.kind else {
            return XCTFail("Expected unknown future kind to round-trip")
        }

        let reencoded = try ServerStoreV2Coding.encoder().encode(envelope)
        let reencodedString = String(decoding: reencoded, as: UTF8.self)
        XCTAssertTrue(reencodedString.contains(#""kind":"futureOS""#))
    }

    func test_v2Storage_isAdditiveAndDoesNotRewriteV1() {
        let suiteName = "ServerStoreV2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerStore(defaults: defaults)
        let envelope = ServerStoreV2Envelope(records: [
            record(id: "linux-alpha", kind: .linux, hostname: "linux-alpha", lastHost: "100.64.0.10"),
        ])

        store.saveV2Envelope(envelope)

        XCTAssertEqual(store.loadV2Envelope(), envelope)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(defaults.data(forKey: ServerStore.storageKey))
    }

    private func record(
        id: String,
        kind: ServerStoreV2Kind,
        hostname: String,
        lastHost: String,
        credentials: [ServerStoreV2CredentialReference] = [],
        legacyProvenance: [ServerStoreV2LegacyProvenance] = []
    ) -> ServerStoreV2Record {
        ServerStoreV2Record(
            server: server(
                id: id,
                kind: kind == .mac ? .mac : .linux,
                hostname: hostname,
                lastHost: lastHost
            ),
            credentials: credentials,
            legacyProvenance: legacyProvenance,
            installProfile: .dev
        )
    }

    private func server(
        id: String,
        kind: Server.Kind,
        hostname: String,
        lastHost: String?,
        engineMachineId: String? = nil,
        apiEndpoint: URL? = nil,
        presencePort: Int? = nil,
        attachPort: Int? = nil
    ) -> Server {
        Server(
            id: id,
            kind: kind,
            pairedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_100),
            alias: nil,
            hostname: hostname,
            lastHost: lastHost,
            engineMachineId: engineMachineId,
            apiEndpoint: apiEndpoint,
            bootstrapEndpoint: nil,
            presencePort: presencePort,
            attachPort: attachPort,
            role: kind == .linux ? "admin" : nil,
            sessionExpiresAt: nil
        )
    }
}
