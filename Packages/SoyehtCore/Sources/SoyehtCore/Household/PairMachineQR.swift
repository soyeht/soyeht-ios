import CryptoKit
import Foundation

public enum PairMachineQRError: Error, Equatable, Sendable {
    case unsupportedScheme
    case unsupportedPath
    case missingField(String)
    case unsupportedVersion(String)
    case invalidMachinePublicKey
    case invalidNonceEncoding
    case invalidNonce
    case emptyHostname
    case unsupportedPlatform(String)
    case unsupportedTransport(String)
    case emptyAddress
    case invalidChallengeSignatureEncoding
    case invalidChallengeSignatureLength(Int)
    case challengeSignatureVerificationFailed
    case invalidExpiry
    case expired
    case ttlExceedsMaxAllowed(seconds: TimeInterval, max: TimeInterval)
}

public enum PairMachinePlatform: String, CaseIterable, Sendable, Equatable {
    case macos
    case linuxNix = "linux-nix"
    case linuxOther = "linux-other"
}

public enum PairMachineTransport: String, CaseIterable, Sendable, Equatable {
    case lan
    case tailscale
}

public struct PairMachineQR: Equatable, Sendable {
    public static let challengeSignatureLength = 64

    /// Defense-in-depth bound on the QR's `ttl` (seconds beyond `now`). The
    /// candidate's install-time `JoinChallenge` does NOT include `ttl`, so
    /// an attacker with a captured QR could otherwise rewrite `ttl` to an
    /// arbitrary future timestamp and the local signature verification would
    /// still pass. Capping at the spec's hard 5-minute window (FR-012) bounds
    /// the practical replay envelope without requiring a cross-repo schema
    /// change. Coordinate with theyos to add `ttl` (and `addr`) to the signed
    /// challenge in v2 to remove this defensive layer entirely.
    public static let defaultMaxTTLSeconds: TimeInterval = 300

    public let version: Int
    public let machinePublicKey: Data
    public let nonce: Data
    public let hostname: String
    public let platform: PairMachinePlatform
    public let transport: PairMachineTransport
    public let address: String
    public let challengeSignature: Data
    public let expiresAt: Date

    public init(
        version: Int,
        machinePublicKey: Data,
        nonce: Data,
        hostname: String,
        platform: PairMachinePlatform,
        transport: PairMachineTransport,
        address: String,
        challengeSignature: Data,
        expiresAt: Date
    ) {
        self.version = version
        self.machinePublicKey = machinePublicKey
        self.nonce = nonce
        self.hostname = hostname
        self.platform = platform
        self.transport = transport
        self.address = address
        self.challengeSignature = challengeSignature
        self.expiresAt = expiresAt
    }

    public init(
        url: URL,
        now: Date = Date(),
        maxTTLSeconds: TimeInterval = PairMachineQR.defaultMaxTTLSeconds
    ) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "soyeht" else {
            throw PairMachineQRError.unsupportedScheme
        }
        guard components.host == "household", components.path == "/pair-machine" else {
            throw PairMachineQRError.unsupportedPath
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        guard let versionValue = value("v") else { throw PairMachineQRError.missingField("v") }
        guard versionValue == "1" else { throw PairMachineQRError.unsupportedVersion(versionValue) }

        guard let mPubValue = value("m_pub") else { throw PairMachineQRError.missingField("m_pub") }
        let machinePublicKey: Data
        do {
            machinePublicKey = try Data(soyehtBase64URL: mPubValue)
            try HouseholdIdentifiers.validateCompressedP256PublicKey(machinePublicKey)
        } catch {
            throw PairMachineQRError.invalidMachinePublicKey
        }

        guard let nonceValue = value("nonce") else { throw PairMachineQRError.missingField("nonce") }
        let nonce: Data
        do {
            nonce = try Data(soyehtBase64URL: nonceValue)
        } catch {
            throw PairMachineQRError.invalidNonceEncoding
        }
        guard !nonce.isEmpty else { throw PairMachineQRError.invalidNonce }

        guard let hostnameRaw = value("hostname") else {
            throw PairMachineQRError.missingField("hostname")
        }
        // URLComponents already percent-decodes query item values.
        guard !hostnameRaw.isEmpty else { throw PairMachineQRError.emptyHostname }

        guard let platformValue = value("platform") else {
            throw PairMachineQRError.missingField("platform")
        }
        guard let platform = PairMachinePlatform(rawValue: platformValue) else {
            throw PairMachineQRError.unsupportedPlatform(platformValue)
        }

        guard let transportValue = value("transport") else {
            throw PairMachineQRError.missingField("transport")
        }
        guard let transport = PairMachineTransport(rawValue: transportValue) else {
            throw PairMachineQRError.unsupportedTransport(transportValue)
        }

        guard let address = value("addr") else {
            throw PairMachineQRError.missingField("addr")
        }
        guard !address.isEmpty else { throw PairMachineQRError.emptyAddress }

        guard let challengeSigValue = value("challenge_sig") else {
            throw PairMachineQRError.missingField("challenge_sig")
        }
        let challengeSignature: Data
        do {
            challengeSignature = try Data(soyehtBase64URL: challengeSigValue)
        } catch {
            throw PairMachineQRError.invalidChallengeSignatureEncoding
        }
        guard challengeSignature.count == Self.challengeSignatureLength else {
            throw PairMachineQRError.invalidChallengeSignatureLength(challengeSignature.count)
        }

        guard let ttlValue = value("ttl") else {
            throw PairMachineQRError.missingField("ttl")
        }
        guard let ttlTimestamp = TimeInterval(ttlValue), ttlTimestamp > 0 else {
            throw PairMachineQRError.invalidExpiry
        }
        let expiresAt = Date(timeIntervalSince1970: ttlTimestamp)
        guard expiresAt > now else { throw PairMachineQRError.expired }
        let secondsToExpiry = expiresAt.timeIntervalSince(now)
        guard secondsToExpiry <= maxTTLSeconds else {
            throw PairMachineQRError.ttlExceedsMaxAllowed(
                seconds: secondsToExpiry,
                max: maxTTLSeconds
            )
        }

        // FR-029: verify the candidate's challenge signature LOCALLY before
        // returning a successful parse. The CBOR JoinChallenge MUST be
        // reconstructed from the same fields the candidate hashed at install
        // time; any tamper to hostname/platform/m_pub/nonce breaks verification.
        try Self.verifyChallengeSignature(
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            hostname: hostnameRaw,
            platform: platform.rawValue,
            signature: challengeSignature
        )

        self.init(
            version: 1,
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            hostname: hostnameRaw,
            platform: platform,
            transport: transport,
            address: address,
            challengeSignature: challengeSignature,
            expiresAt: expiresAt
        )
    }

    public static func verifyChallengeSignature(
        machinePublicKey: Data,
        nonce: Data,
        hostname: String,
        platform: String,
        signature: Data
    ) throws {
        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(compressedRepresentation: machinePublicKey)
        } catch {
            throw PairMachineQRError.invalidMachinePublicKey
        }
        let ecdsaSignature: P256.Signing.ECDSASignature
        do {
            ecdsaSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        } catch {
            throw PairMachineQRError.invalidChallengeSignatureEncoding
        }
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: machinePublicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        guard publicKey.isValidSignature(ecdsaSignature, for: challenge) else {
            throw PairMachineQRError.challengeSignatureVerificationFailed
        }
    }
}
