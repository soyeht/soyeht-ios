import Foundation

/// Public authority identifiers used to check whether this Mac can approve.
/// Receiving them does not grant authority; an owner signature is still required.
public struct PairingAuthority: Equatable, Sendable {
    public let householdID: String?
    public let ownerPersonID: String?
    public let ownerPublicKey: Data?

    public init(householdID: String?, ownerPersonID: String?, ownerPublicKey: Data?) {
        self.householdID = householdID
        self.ownerPersonID = ownerPersonID
        self.ownerPublicKey = ownerPublicKey
    }
}

public struct PairingAddressSnapshot: Equatable, Sendable {
    public let offer: PairingAddressOffer
    public let authority: PairingAuthority
}

/// Reads actual listeners and available ceremonies. No local interface fallback:
/// a missing snapshot must not be represented as a verified engine address.
public struct BootstrapPairingAddressesClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public static let path = "/bootstrap/pairing-addresses"
    private let baseURL: URL
    private let installation: PairingInstallIdentity
    private let perform: TransportPerform

    public init(baseURL: URL, installation: PairingInstallIdentity = .current,
                transport: @escaping TransportPerform = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.installation = installation
        self.perform = transport
    }

    public func fetch() async throws -> PairingAddressSnapshot {
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(BootstrapWire.contentType, forHTTPHeaderField: "Accept")
        do {
            let (body, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse else {
                throw PairingAttemptFailure(stage: .discovery, endpoint: url, cause: .invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PairingAttemptFailure(stage: .discovery, endpoint: url, cause: .server(status: http.statusCode))
            }
            guard BootstrapWire.isCBORContentType(http.value(forHTTPHeaderField: "Content-Type")) else {
                throw PairingAttemptFailure(stage: .discovery, endpoint: url, cause: .invalidResponse)
            }
            return try Self.decode(body, expectedInstallation: installation)
        } catch {
            try PairingAttemptFailure.rethrow(error, stage: .discovery, endpoint: url)
        }
    }

    static func decode(_ data: Data, expectedInstallation: PairingInstallIdentity) throws -> PairingAddressSnapshot {
        guard case .map(let map) = try BootstrapWire.decodeCanonical(data),
              case .unsigned(1) = map["v"],
              case .map(let profile) = map["installation"],
              case .text(let name) = profile["profile"],
              case .unsigned(let port) = profile["bootstrap_port"], port <= 65535,
              case .text(let generation) = map["generation"], !generation.isEmpty,
              case .array(let rawCandidates) = map["candidates"],
              case .map(let authority) = map["authority"] else {
            throw PairingAddressError.unsupportedVersion
        }
        let installation = PairingInstallIdentity(profile: name, bootstrapPort: Int(port))
        try installation.requireMatch(expectedInstallation)
        let candidates = try rawCandidates.map { value -> PairingAddressCandidate in
            guard case .map(let c) = value,
                  case .text(let rawURL) = c["url"], let url = URL(string: rawURL),
                  case .text(let rawTransport) = c["transport"], let transport = PairingTransport(rawValue: rawTransport),
                  case .text("listening") = c["availability"],
                  case .array(let rawOperations) = c["operations"] else {
                throw PairingAddressError.invalidEndpoint
            }
            let operations = try rawOperations.map { value -> PairingOperation in
                guard case .text(let raw) = value, let operation = PairingOperation(rawValue: raw) else {
                    throw PairingAddressError.operationUnavailable
                }
                return operation
            }
            let expiry: Date?
            switch c["expires_at_unix"] {
            case .unsigned(let seconds): expiry = Date(timeIntervalSince1970: TimeInterval(seconds))
            case .null: expiry = nil
            default: throw PairingAddressError.invalidEndpoint
            }
            return PairingAddressCandidate(url: url, transport: transport, operations: Set(operations),
                                           availability: .listening, expiresAt: expiry)
        }
        func optionalText(_ key: String) throws -> String? {
            switch authority[key] {
            case .text(let value) where !value.isEmpty: return value
            case .null: return nil
            default: throw PairingAddressError.invalidEndpoint
            }
        }
        let publicKey: Data?
        switch authority["owner_public_key"] {
        case .bytes(let bytes) where bytes.count == 33: publicKey = bytes
        case .null: publicKey = nil
        default: throw PairingAddressError.invalidEndpoint
        }
        let owner = try optionalText("owner_person_id")
        let household = try optionalText("household_id")
        guard (owner == nil) == (publicKey == nil), owner == nil || household != nil else {
            throw PairingAddressError.invalidEndpoint
        }
        return PairingAddressSnapshot(
            offer: PairingAddressOffer(installation: installation, generation: generation, candidates: candidates),
            authority: PairingAuthority(householdID: household, ownerPersonID: owner, ownerPublicKey: publicKey))
    }
}
