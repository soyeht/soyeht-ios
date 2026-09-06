import Foundation

/// The installation the invitation is meant for. This is independent of the
/// iPhone's invitation-listener port and of a proxy's public port.
public struct PairingInstallIdentity: Codable, Equatable, Sendable {
    public let profile: String
    public let bootstrapPort: Int

    public init(profile: String, bootstrapPort: Int) {
        self.profile = profile
        self.bootstrapPort = bootstrapPort
    }

    public init(_ installation: SoyehtInstallProfile) {
        self.init(profile: installation.kind.rawValue, bootstrapPort: installation.bootstrapPort)
    }

    public static var current: Self { Self(SoyehtInstallProfile.current) }

    enum CodingKeys: String, CodingKey {
        case profile
        case bootstrapPort = "bootstrap_port"
    }

    public func requireMatch(_ expected: Self) throws {
        guard (1...65535).contains(bootstrapPort), self == expected else {
            throw PairingAddressError.profileMismatch
        }
    }
}

public enum PairingOperation: String, Codable, CaseIterable, Sendable {
    case initialize
    case firstOwner = "first_owner"
    case addDevice = "add_device"
    case acceptHousehold = "accept_household"
}

public enum PairingTransport: String, Codable, Sendable {
    case tailnet
    case localNetwork = "lan"
    case relay
}

public struct PairingAddressCandidate: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable {
        case listening
        /// Compatibility input from a link without a listener snapshot.
        /// It may be attempted, but must not be described as verified.
        case advertised
    }

    public let url: URL
    public let transport: PairingTransport
    public let operations: Set<PairingOperation>
    public let availability: Availability
    public let expiresAt: Date?

    public init(url: URL, transport: PairingTransport,
                operations: Set<PairingOperation>, availability: Availability,
                expiresAt: Date? = nil) {
        self.url = url
        self.transport = transport
        self.operations = operations
        self.availability = availability
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case url, transport, operations, availability
        case expiresAt = "expires_at_unix"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        transport = try values.decode(PairingTransport.self, forKey: .transport)
        operations = Set(try values.decode([PairingOperation].self, forKey: .operations))
        availability = try values.decode(Availability.self, forKey: .availability)
        expiresAt = try values.decodeIfPresent(UInt64.self, forKey: .expiresAt)
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url, forKey: .url)
        try values.encode(transport, forKey: .transport)
        try values.encode(operations.sorted { $0.rawValue < $1.rawValue }, forKey: .operations)
        try values.encode(availability, forKey: .availability)
        if let expiresAt {
            let seconds = expiresAt.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else {
                throw EncodingError.invalidValue(expiresAt, .init(codingPath: encoder.codingPath,
                                                                  debugDescription: "Invalid Unix deadline"))
            }
            try values.encode(UInt64(seconds), forKey: .expiresAt)
        } else {
            try values.encodeNil(forKey: .expiresAt)
        }
    }
}

public struct PairingAddressOffer: Codable, Equatable, Sendable {
    public let version: Int
    public let installation: PairingInstallIdentity
    public let generation: String
    public let candidates: [PairingAddressCandidate]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case installation, generation, candidates
    }

    public init(version: Int = 1, installation: PairingInstallIdentity,
                generation: String, candidates: [PairingAddressCandidate]) {
        self.version = version
        self.installation = installation
        self.generation = generation
        self.candidates = candidates
    }
}

public struct PhoneNetworkEvidence: Equatable, Sendable {
    /// nil means the reader has no phone observation (for example a Mac
    /// displaying a QR). An interface is capability evidence, not a probe.
    public let hasTailnetAddress: Bool?
    public let reachedEndpoints: Set<URL>

    public init(hasTailnetAddress: Bool?, reachedEndpoints: Set<URL> = []) {
        self.hasTailnetAddress = hasTailnetAddress
        self.reachedEndpoints = reachedEndpoints
    }

    public static func current(reachedEndpoints: Set<URL> = []) -> Self {
        Self(hasTailnetAddress: TailnetAddressResolver.currentHasTailnetAddress(),
             reachedEndpoints: reachedEndpoints)
    }
}

public enum PairingAddressError: String, Error, Equatable, Sendable {
    case profileMissing = "profile_missing"
    case profileMismatch = "profile_mismatch"
    case unsupportedVersion = "unsupported_version"
    case invalidEndpoint = "invalid_endpoint"
    case noAvailableEndpoint = "no_available_endpoint"
    case operationUnavailable = "operation_unavailable"
    case noReachableAddress = "no_reachable_address"
    case expiredOffer = "expired_offer"
    case staleDecision = "stale_decision"
}

public struct PairingAddressDecision: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case tailnetOnBothEnds
        case localNetworkFallback
        case reachedEndpoint
        case advertised
    }

    public let candidate: PairingAddressCandidate
    public let operation: PairingOperation
    public let installation: PairingInstallIdentity
    public let generation: String
    public let reason: Reason
    public var url: URL { candidate.url }
}

/// One ranking rule for discovery, claims, QR, confirmation and persistence.
/// Listener and route authorization remain engine facts, never side effects
/// of choosing an address. Callers must report a failed attempt, not silently
/// replace a tailnet decision with a LAN endpoint that responded earlier.
public enum PairingAddressPolicy {
    /// Decode old advertisements into evidence without a second ranking rule.
    public static func legacyOffer(
        endpoints: [URL], installation: PairingInstallIdentity
    ) -> PairingAddressOffer {
        var seen = Set<URL>()
        let candidates = endpoints.compactMap { url -> PairingAddressCandidate? in
            guard seen.insert(url).inserted, let transport = transport(of: url) else { return nil }
            return PairingAddressCandidate(url: url, transport: transport,
                                           operations: Set(PairingOperation.allCases),
                                           availability: .advertised)
        }
        return PairingAddressOffer(installation: installation, generation: "legacy-advertisement",
                                   candidates: candidates)
    }

    public static func choose(
        offer: PairingAddressOffer,
        expectedInstallation: PairingInstallIdentity,
        phone: PhoneNetworkEvidence,
        operation: PairingOperation,
        now: Date = Date()
    ) throws -> PairingAddressDecision {
        guard offer.version == 1 else { throw PairingAddressError.unsupportedVersion }
        try offer.installation.requireMatch(expectedInstallation)
        guard !offer.candidates.isEmpty else { throw PairingAddressError.noAvailableEndpoint }

        // A malformed alternate must not become a second opportunity to
        // contact loopback, a different profile, or a credential-bearing URL.
        let valid = offer.candidates.filter { isValid($0, installation: offer.installation) }
        guard !valid.isEmpty else { throw PairingAddressError.invalidEndpoint }
        let live = valid.filter { $0.expiresAt.map { $0 > now } ?? true }
        guard !live.isEmpty else { throw PairingAddressError.expiredOffer }
        let allowed = live.filter { $0.operations.contains(operation) }
        guard !allowed.isEmpty else { throw PairingAddressError.operationUnavailable }
        let eligible = allowed.filter {
            $0.transport != .tailnet || phone.hasTailnetAddress != false
        }
        guard !eligible.isEmpty else { throw PairingAddressError.noReachableAddress }

        guard let chosen = eligible.enumerated().min(by: { lhs, rhs in
            let l = rank(lhs.element, phone: phone)
            let r = rank(rhs.element, phone: phone)
            return l == r ? lhs.offset < rhs.offset : l < r
        })?.element else { throw PairingAddressError.noReachableAddress }
        let reason: PairingAddressDecision.Reason
        if chosen.transport == .tailnet, phone.hasTailnetAddress == true {
            reason = .tailnetOnBothEnds
        } else if chosen.transport == .localNetwork, phone.hasTailnetAddress == false {
            reason = .localNetworkFallback
        } else if phone.reachedEndpoints.contains(chosen.url) {
            reason = .reachedEndpoint
        } else {
            reason = .advertised
        }
        return PairingAddressDecision(candidate: chosen, operation: operation,
                                      installation: offer.installation,
                                      generation: offer.generation, reason: reason)
    }

    /// Revalidate before using an old selection after an offer refresh.
    /// A successful HTTP exchange/proof is still required by the ceremony.
    public static func validate(_ decision: PairingAddressDecision,
                                against offer: PairingAddressOffer,
                                now: Date = Date()) throws {
        guard offer.version == 1 else { throw PairingAddressError.unsupportedVersion }
        guard decision.installation == offer.installation,
              decision.generation == offer.generation,
              offer.candidates.contains(decision.candidate) else {
            throw PairingAddressError.staleDecision
        }
        if let expires = decision.candidate.expiresAt, expires <= now {
            throw PairingAddressError.expiredOffer
        }
    }

    public static func transport(of url: URL) -> PairingTransport? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch HostClassifier.classify(normalized) {
        case .tailnet: return .tailnet
        case .lan: return .localNetwork
        case .publicHost: return url.scheme?.lowercased() == "https" ? .relay : nil
        case .loopback, .unknown: return nil
        }
    }

    private static func isValid(_ candidate: PairingAddressCandidate,
                                installation: PairingInstallIdentity) -> Bool {
        guard let components = URLComponents(url: candidate.url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.scheme == "http" || components.scheme == "https",
              host != "localhost", host != "::1", host != "[::1]",
              host != "0.0.0.0", host != "::", host != "[::]",
              !host.hasPrefix("127."),
              transport(of: candidate.url) == candidate.transport else { return false }
        if candidate.transport == .relay {
            return components.scheme == "https"
        }
        return components.port == installation.bootstrapPort
    }

    private static func rank(_ candidate: PairingAddressCandidate,
                             phone: PhoneNetworkEvidence) -> Int {
        // Unknown capability is not evidence that the durable route is
        // unavailable. Do not let an earlier LAN exchange silently replace it.
        if candidate.transport == .tailnet, phone.hasTailnetAddress != false { return 0 }
        if phone.reachedEndpoints.contains(candidate.url) { return 1 }
        switch candidate.transport {
        case .tailnet: return 2
        case .relay: return 3
        case .localNetwork: return 4
        }
    }
}
