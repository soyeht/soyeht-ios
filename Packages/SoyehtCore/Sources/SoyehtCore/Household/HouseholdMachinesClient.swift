import Foundation

/// One identity-only machine record returned by the owner-authenticated
/// `GET /api/v1/household/machines` contract.
///
/// `machineID` is derived from the validated compressed P-256 public key in
/// `machine_pub`; a server-supplied string is never accepted as an identity on
/// its own. This payload deliberately carries no route, secret, certificate
/// signature, or presence claim.
public struct HouseholdMachine: Equatable, Sendable {
    public let machineID: MachineID
    public let hostLabel: String
    /// Engine-defined platform vocabulary. Keep this forward-compatible: it
    /// identifies the record for presentation, not a routing policy.
    public let platform: String
    public let isSelf: Bool
    public let capabilities: [String]
    /// Epoch seconds emitted by the engine's machine inventory.
    public let joinedAt: UInt64

    public init(
        machineID: MachineID,
        hostLabel: String,
        platform: String,
        isSelf: Bool,
        capabilities: [String],
        joinedAt: UInt64
    ) {
        self.machineID = machineID
        self.hostLabel = hostLabel
        self.platform = platform
        self.isSelf = isSelf
        self.capabilities = capabilities
        self.joinedAt = joinedAt
    }
}

/// Validated owner-authenticated machine inventory.
///
/// The response's `self_m_id` and `is_self` marker must name the same unique
/// record. Only then does it create a `MachineReachabilityAuthority`: a
/// household member is not implicitly the endpoint's respondent.
public struct HouseholdMachinesSnapshot: Equatable, Sendable {
    public let householdID: String
    public let selfMachine: HouseholdMachine
    public let machines: [HouseholdMachine]
    public let reachabilityAuthority: MachineReachabilityAuthority

    public init(
        householdID: String,
        selfMachine: HouseholdMachine,
        machines: [HouseholdMachine],
        reachabilityAuthority: MachineReachabilityAuthority
    ) {
        self.householdID = householdID
        self.selfMachine = selfMachine
        self.machines = machines
        self.reachabilityAuthority = reachabilityAuthority
    }
}

/// Fail-closed errors for the identity inventory. The engine is permitted to
/// omit a self record when its local state is incomplete; callers must treat
/// that as unresolved authority rather than selecting another machine.
public enum HouseholdMachinesError: Error, Equatable, Sendable {
    case networkDrop
    case unexpectedResponse
    case unexpectedContentType(String?)
    case unauthorized
    case unexpectedHTTPStatus(Int)
    case unsupportedEnvelopeVersion(UInt64)
    case householdIDMismatch(expected: String, actual: String)
    case invalidMachinePublicKey
    case machineIdentifierMismatch
    case duplicateMachineIdentifier
    case missingSelfMachineIdentifier
    case inconsistentSelfMachineBinding
}

/// Owner-PoP client for `GET /api/v1/household/machines`.
///
/// The client receives a base URL and an already-created owner signer; it
/// neither loads `ActiveHouseholdState` nor reads its legacy endpoint. The
/// one-time authority bootstrap is deliberately owned by the reachability seam
/// so this client remains a normal, explicit HTTP contract client.
public struct HouseholdMachinesClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let path = "/api/v1/household/machines"

    private let baseURL: URL
    private let expectedHouseholdID: String
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        expectedHouseholdID: String,
        popSigner: HouseholdPoPSigner,
        transport: @escaping TransportPerform = { request in
            try await BootstrapInitializeClient.defaultSession.data(for: request)
        }
    ) {
        self.baseURL = baseURL
        self.expectedHouseholdID = expectedHouseholdID
        self.popSigner = popSigner
        self.perform = transport
    }

    public func fetch() async throws -> HouseholdMachinesSnapshot {
        let (url, pathAndQuery) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let authorization = try popSigner
            .authorization(method: "GET", pathAndQuery: pathAndQuery, body: Data())
            .authorizationHeader

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw HouseholdMachinesError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw HouseholdMachinesError.unexpectedResponse
        }
        guard Self.isJSONContentType(http.value(forHTTPHeaderField: "Content-Type")) else {
            throw HouseholdMachinesError.unexpectedContentType(
                http.value(forHTTPHeaderField: "Content-Type")
            )
        }
        guard http.statusCode != 401 else {
            throw HouseholdMachinesError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HouseholdMachinesError.unexpectedHTTPStatus(http.statusCode)
        }

        let wire: WireResponse
        do {
            wire = try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw HouseholdMachinesError.unexpectedResponse
        }
        return try Self.validate(wire, expectedHouseholdID: expectedHouseholdID)
    }

    // MARK: - Validation

    private static func validate(
        _ wire: WireResponse,
        expectedHouseholdID: String
    ) throws -> HouseholdMachinesSnapshot {
        guard wire.version == 1 else {
            throw HouseholdMachinesError.unsupportedEnvelopeVersion(wire.version)
        }
        guard wire.householdID == expectedHouseholdID else {
            throw HouseholdMachinesError.householdIDMismatch(
                expected: expectedHouseholdID,
                actual: wire.householdID
            )
        }

        var machineIDs = Set<MachineID>()
        let machines = try wire.machines.map { rawMachine -> HouseholdMachine in
            let machinePublicKey: Data
            do {
                machinePublicKey = try decodeLowerHexPublicKey(rawMachine.machinePublicKey)
            } catch {
                throw HouseholdMachinesError.invalidMachinePublicKey
            }

            let machineID: MachineID
            do {
                machineID = try MachineID(authenticatedMachinePublicKey: machinePublicKey)
            } catch {
                throw HouseholdMachinesError.invalidMachinePublicKey
            }
            guard machineID.rawValue == rawMachine.machineID else {
                throw HouseholdMachinesError.machineIdentifierMismatch
            }
            guard machineIDs.insert(machineID).inserted else {
                throw HouseholdMachinesError.duplicateMachineIdentifier
            }
            return HouseholdMachine(
                machineID: machineID,
                hostLabel: rawMachine.hostLabel,
                platform: rawMachine.platform,
                isSelf: rawMachine.isSelf,
                capabilities: rawMachine.capabilities,
                joinedAt: rawMachine.joinedAt
            )
        }

        guard let reportedSelfMachineID = wire.reportedSelfMachineID,
              !reportedSelfMachineID.isEmpty else {
            throw HouseholdMachinesError.missingSelfMachineIdentifier
        }

        let explicitlySelf = machines.filter(\.isSelf)
        let reportedSelf = machines.filter { $0.machineID.rawValue == reportedSelfMachineID }
        guard explicitlySelf.count == 1,
              reportedSelf.count == 1,
              explicitlySelf[0].machineID == reportedSelf[0].machineID else {
            throw HouseholdMachinesError.inconsistentSelfMachineBinding
        }
        let selfMachine = explicitlySelf[0]

        let authority: MachineReachabilityAuthority
        do {
            authority = try MachineReachabilityAuthority(
                householdID: wire.householdID,
                reportedSelfMachineID: reportedSelfMachineID,
                authenticatedSelfMachinePublicKey: selfMachine.machineID.machinePublicKey
            )
        } catch {
            // The checks above make this branch defensive, but keep the
            // response boundary fail-closed if MachineID changes later.
            throw HouseholdMachinesError.inconsistentSelfMachineBinding
        }

        return HouseholdMachinesSnapshot(
            householdID: wire.householdID,
            selfMachine: selfMachine,
            machines: machines,
            reachabilityAuthority: authority
        )
    }

    private static func decodeLowerHexPublicKey(_ value: String) throws -> Data {
        guard value.utf8.count == HouseholdIdentifiers.compressedP256PublicKeyLength * 2,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102:
                      true
                  default:
                      false
                  }
              }) else {
            throw HouseholdMachinesError.invalidMachinePublicKey
        }

        var result = Data()
        result.reserveCapacity(HouseholdIdentifiers.compressedP256PublicKeyLength)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw HouseholdMachinesError.invalidMachinePublicKey
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func isJSONContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == "application/json"
    }

    // MARK: - Wire DTOs

    private struct WireResponse: Decodable {
        let version: UInt64
        let householdID: String
        let reportedSelfMachineID: String?
        let machines: [WireMachine]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case householdID = "hh_id"
            case reportedSelfMachineID = "self_m_id"
            case machines
        }
    }

    private struct WireMachine: Decodable {
        let machineID: String
        let machinePublicKey: String
        let hostLabel: String
        let platform: String
        let isSelf: Bool
        let capabilities: [String]
        let joinedAt: UInt64

        enum CodingKeys: String, CodingKey {
            case machineID = "machine_id"
            case machinePublicKey = "machine_pub"
            case hostLabel = "host_label"
            case platform
            case isSelf = "is_self"
            case capabilities
            case joinedAt = "joined_at"
        }
    }
}
