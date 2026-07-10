import CryptoKit
import Foundation
import LocalAuthentication
import Security

let challengeContract = "mobile_claw_vpn_dev_local_presence_challenge_v1"
let challengeDomain = Data("soyeht-mobile-claw-vpn-dev-local-presence-v1".utf8) + Data([0])
let maximumChallengeTTL: Int64 = 120
let maximumInputBytes = 65_536

enum LocalPresenceError: Error, Equatable {
    case invalidArguments
    case inputInvalid
    case challengeInvalid
    case secureEnclaveUnavailable
    case localBiometricPresenceFailed

    var reason: String {
        switch self {
        case .invalidArguments: "local_presence_argument_refused"
        case .inputInvalid: "local_presence_input_refused"
        case .challengeInvalid: "local_presence_challenge_refused"
        case .secureEnclaveUnavailable: "secure_enclave_unavailable"
        case .localBiometricPresenceFailed: "local_biometric_presence_failed"
        }
    }
}

struct LocalPresenceChallenge: Codable, Equatable {
    static let expectedKeys: Set<String> = [
        "contract", "attempt_id", "readiness_run_id", "artifact_sha",
        "execution_manifest_sha256", "device_binding", "execution_run_id",
        "replay_nonce", "created_at_unix", "expires_at_unix", "bundle_id",
        "device_alias", "claw_alias", "owner_present_required",
        "raw_values_printed",
    ]

    let contract: String
    let attemptID: String
    let readinessRunID: String
    let artifactSHA: String
    let executionManifestSHA256: String
    let deviceBinding: String
    let executionRunID: String
    let replayNonce: String
    let createdAtUnix: Int64
    let expiresAtUnix: Int64
    let bundleID: String
    let deviceAlias: String
    let clawAlias: String
    let ownerPresentRequired: Bool
    let rawValuesPrinted: Bool

    enum CodingKeys: String, CodingKey {
        case contract
        case attemptID = "attempt_id"
        case readinessRunID = "readiness_run_id"
        case artifactSHA = "artifact_sha"
        case executionManifestSHA256 = "execution_manifest_sha256"
        case deviceBinding = "device_binding"
        case executionRunID = "execution_run_id"
        case replayNonce = "replay_nonce"
        case createdAtUnix = "created_at_unix"
        case expiresAtUnix = "expires_at_unix"
        case bundleID = "bundle_id"
        case deviceAlias = "device_alias"
        case clawAlias = "claw_alias"
        case ownerPresentRequired = "owner_present_required"
        case rawValuesPrinted = "raw_values_printed"
    }

    func validate(now: Int64) throws {
        let ttl = expiresAtUnix.subtractingReportingOverflow(createdAtUnix)
        guard contract == challengeContract,
              Self.isCanonicalUUID(attemptID),
              Self.isCanonicalUUID(readinessRunID),
              Self.isCanonicalUUID(executionRunID),
              Self.isLowercaseHex(artifactSHA, length: 40),
              Self.isLowercaseHex(executionManifestSHA256, length: 64),
              Self.isLowercaseHex(deviceBinding, length: 64),
              Self.isLowercaseHex(replayNonce, length: 64),
              createdAtUnix <= now,
              expiresAtUnix > now,
              !ttl.overflow,
              ttl.partialValue > 0,
              ttl.partialValue <= maximumChallengeTTL,
              bundleID == "com.soyeht.app.dev",
              deviceAlias == "Device-D",
              ["Claw-M", "Claw-L"].contains(clawAlias),
              ownerPresentRequired,
              !rawValuesPrinted else {
            throw LocalPresenceError.challengeInvalid
        }
    }

    func digest() -> Data {
        var material = challengeDomain
        for value in [
            contract,
            attemptID,
            readinessRunID,
            artifactSHA,
            executionManifestSHA256,
            deviceBinding,
            executionRunID,
            replayNonce,
            String(createdAtUnix),
            String(expiresAtUnix),
            bundleID,
            deviceAlias,
            clawAlias,
            ownerPresentRequired ? "true" : "false",
            rawValuesPrinted ? "true" : "false",
        ] {
            material.append(Data(value.utf8))
            material.append(0)
        }
        return Data(SHA256.hash(data: material))
    }

    var localizedReview: String {
        "Approve local biometric presence for \(deviceAlias) to \(clawAlias), " +
            "DEV source \(artifactSHA.prefix(12)), " +
            "build \(executionManifestSHA256.prefix(12)), " +
            "run \(executionRunID.prefix(8))."
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.lowercased() == value
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

struct PublicResult: Encodable {
    let status: String
    let reason: String?
    let challengeSHA256: String?
    let executionRunID: String?
    let localBiometricPresenceObserved: Bool
    let ownerAuthenticated: Bool
    let executionAuthorized: Bool
    let appLaunchAttempted: Bool
    let rawValuesPrinted: Bool

    enum CodingKeys: String, CodingKey {
        case status, reason
        case challengeSHA256 = "challenge_sha256"
        case executionRunID = "execution_run_id"
        case localBiometricPresenceObserved = "local_biometric_presence_observed"
        case ownerAuthenticated = "owner_authenticated"
        case executionAuthorized = "execution_authorized"
        case appLaunchAttempted = "app_launch_attempted"
        case rawValuesPrinted = "raw_values_printed"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let reason {
            try container.encode(reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .reason)
        }
        if let challengeSHA256 {
            try container.encode(challengeSHA256, forKey: .challengeSHA256)
        } else {
            try container.encodeNil(forKey: .challengeSHA256)
        }
        if let executionRunID {
            try container.encode(executionRunID, forKey: .executionRunID)
        } else {
            try container.encodeNil(forKey: .executionRunID)
        }
        try container.encode(
            localBiometricPresenceObserved,
            forKey: .localBiometricPresenceObserved
        )
        try container.encode(ownerAuthenticated, forKey: .ownerAuthenticated)
        try container.encode(executionAuthorized, forKey: .executionAuthorized)
        try container.encode(appLaunchAttempted, forKey: .appLaunchAttempted)
        try container.encode(rawValuesPrinted, forKey: .rawValuesPrinted)
    }
}

enum LocalPresenceEngine {
    typealias Clock = () -> Int64
    typealias Observe = (LocalPresenceChallenge, Data) throws -> Bool

    static func execute(
        input: Data,
        clock: Clock,
        observe: Observe
    ) throws -> PublicResult {
        let challenge = try decodeCanonicalChallenge(input)
        try challenge.validate(now: clock())
        let digest = challenge.digest()
        guard try observe(challenge, digest) else {
            throw LocalPresenceError.localBiometricPresenceFailed
        }
        try challenge.validate(now: clock())
        return PublicResult(
            status: "local_biometric_presence_observed",
            reason: nil,
            challengeSHA256: hex(digest),
            executionRunID: challenge.executionRunID,
            localBiometricPresenceObserved: true,
            ownerAuthenticated: false,
            executionAuthorized: false,
            appLaunchAttempted: false,
            rawValuesPrinted: false
        )
    }

    static func decodeCanonicalChallenge(_ input: Data) throws -> LocalPresenceChallenge {
        guard !input.isEmpty, input.count <= maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: input),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == LocalPresenceChallenge.expectedKeys,
              let canonical = try? JSONSerialization.data(
                  withJSONObject: dictionary,
                  options: [.sortedKeys]
              ),
              canonical == input else {
            throw LocalPresenceError.inputInvalid
        }
        do {
            return try JSONDecoder().decode(LocalPresenceChallenge.self, from: input)
        } catch {
            throw LocalPresenceError.inputInvalid
        }
    }
}

private func observeLocalBiometricPresence(
    challenge: LocalPresenceChallenge,
    digest: Data
) throws -> Bool {
    guard SecureEnclave.isAvailable else {
        throw LocalPresenceError.secureEnclaveUnavailable
    }
    guard let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .biometryCurrentSet],
        nil
    ) else {
        throw LocalPresenceError.localBiometricPresenceFailed
    }

    let context = LAContext()
    context.touchIDAuthenticationAllowableReuseDuration = 0
    context.localizedCancelTitle = "Cancel"
    context.localizedReason = challenge.localizedReview
    defer { context.invalidate() }

    let privateKey: SecureEnclave.P256.Signing.PrivateKey
    do {
        privateKey = try SecureEnclave.P256.Signing.PrivateKey(
            accessControl: accessControl,
            authenticationContext: context
        )
        let signature = try privateKey.signature(for: digest)
        return privateKey.publicKey.isValidSignature(signature, for: digest)
    } catch {
        throw LocalPresenceError.localBiometricPresenceFailed
    }
}

private func failure(_ status: String, _ reason: String) -> PublicResult {
    PublicResult(
        status: status,
        reason: reason,
        challengeSHA256: nil,
        executionRunID: nil,
        localBiometricPresenceObserved: false,
        ownerAuthenticated: false,
        executionAuthorized: false,
        appLaunchAttempted: false,
        rawValuesPrinted: false
    )
}

private func emit(_ result: PublicResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(result),
          let text = String(data: data, encoding: .utf8) else {
        fputs("{\"status\":\"failed\",\"reason\":\"local_presence_output_failed\"}\n", stdout)
        return
    }
    fputs(text + "\n", stdout)
}

func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func readBoundedStandardInput() throws -> Data {
    var input = Data()
    while true {
        let remaining = maximumInputBytes + 1 - input.count
        guard remaining > 0 else { throw LocalPresenceError.inputInvalid }
        guard let chunk = try FileHandle.standardInput.read(
            upToCount: min(8_192, remaining)
        ) else {
            break
        }
        if chunk.isEmpty { break }
        input.append(chunk)
        if input.count > maximumInputBytes {
            throw LocalPresenceError.inputInvalid
        }
    }
    return input
}

#if !MOBILE_CLAW_VPN_LOCAL_PRESENCE_SELF_TEST
@main
private enum MobileClawVPNDevLocalPresenceTool {
    static func main() {
        guard CommandLine.arguments.count == 1 else {
            emit(failure("refused", LocalPresenceError.invalidArguments.reason))
            exit(1)
        }
        do {
            let input = try readBoundedStandardInput()
            let result = try LocalPresenceEngine.execute(
                input: input,
                clock: { Int64(Date().timeIntervalSince1970) },
                observe: observeLocalBiometricPresence
            )
            emit(result)
        } catch let error as LocalPresenceError {
            emit(failure("refused", error.reason))
            exit(1)
        } catch {
            emit(failure("failed", "local_presence_internal_error"))
            exit(1)
        }
    }
}
#endif
