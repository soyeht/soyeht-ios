import Darwin
import Foundation
import SoyehtCore
import XCTest

private protocol ProbeStatusSource {
    var productionActivation: Bool { get }
    var snapshotPresent: Bool { get }
    var enrolledDeviceCount: Int { get }
    var availableClawCount: Int { get }
    var grantCount: Int { get }
    var offerCount: Int { get }
    var sessionCount: Int { get }
}

private protocol ProbeAuthorizationSource {
    associatedtype Status: ProbeStatusSource

    var authorized: Bool { get }
    var productionActivation: Bool { get }
    var status: Status { get }
}

extension MobileClawVPNStatusResponse: ProbeStatusSource {}
extension MobileClawVPNRendezvousAuthorization: ProbeAuthorizationSource {}

final class MobileClawVPNOwnerPresentProbeTests: XCTestCase {
    private static let directoryName = "MobileClawVPNDevE2E"
    private static let inputName = "input.json"
    private static let maximumFileBytes: off_t = 65_536
    private static let maximumInputTTL: Int64 = 300

    func testRunOwnerPresentControlPlane() async throws {
        guard Bundle.main.bundleIdentifier == "com.soyeht.app.dev" else {
            XCTFail("Mobile Claw VPN owner-present probe requires the Dev bundle")
            return
        }

        let directory = try probeDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Mobile Claw VPN owner-present probe is opt-in only")
        }

        let input: ProbeInput
        do {
            input = try consumeInput(from: directory, now: currentTime())
        } catch {
            XCTFail("Mobile Claw VPN owner-present probe input was refused")
            return
        }

        let viewModel = await MainActor.run {
            MobileClawVPNRendezvousViewModel()
        }
        await viewModel.authorize(
            deviceId: input.deviceID,
            clawId: input.clawID
        )
        let phase = await MainActor.run { viewModel.phase }

        switch phase {
        case let .authorized(authorization):
            guard authorization.authorized,
                  !authorization.productionActivation,
                  !authorization.status.productionActivation else {
                do {
                    try writeResult(.failed(input: input), to: directory)
                } catch {
                    XCTFail("Mobile Claw VPN owner-present failure result could not be committed")
                    return
                }
                XCTFail("Mobile Claw VPN owner-present probe refused production activation")
                return
            }
            let snapshot = ProbeAuthorizationSnapshot(authorization: authorization)
            let result = ProbeResult.passed(input: input, authorization: snapshot)
            do {
                try writeResult(result, to: directory)
            } catch {
                XCTFail("Mobile Claw VPN owner-present result could not be committed")
            }
        default:
            do {
                try writeResult(.failed(input: input), to: directory)
            } catch {
                XCTFail("Mobile Claw VPN owner-present failure result could not be committed")
                return
            }
            XCTFail("Mobile Claw VPN control-plane authorization failed")
        }
    }

    func testProbeInputIsStrictAndConsumedBeforeUse() throws {
        let root = try temporaryPrivateDirectory(name: "valid")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = ProbeInput.fixture()
        try writeFixture(input, to: root.appendingPathComponent(Self.inputName))

        let consumed = try consumeInput(from: root, now: 101)
        XCTAssertEqual(consumed, input)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(Self.inputName).path
            )
        )
        XCTAssertThrowsError(try consumeInput(from: root, now: 101))
    }

    func testProbeInputRejectsSchemaModeExpiryAndExtraFiles() throws {
        for variant in InputVariant.allCases {
            let root = try temporaryPrivateDirectory(name: variant.rawValue)
            defer { try? FileManager.default.removeItem(at: root) }
            let inputURL = root.appendingPathComponent(Self.inputName)
            var input = ProbeInput.fixture()

            switch variant {
            case .expired:
                input.expiresAtUnix = 101
                try writeFixture(input, to: inputURL)
            case .ttlTooLong:
                input.expiresAtUnix = 401
                try writeFixture(input, to: inputURL)
            case .ttlOverflow:
                input.createdAtUnix = .min
                input.expiresAtUnix = .max
                try writeFixture(input, to: inputURL)
            case .ownerPresenceMissing:
                input.localBiometricPresenceObserved = false
                try writeFixture(input, to: inputURL)
            case .mode:
                try writeFixture(input, to: inputURL)
                XCTAssertEqual(chmod(inputURL.path, 0o640), 0)
            case .extraField:
                let encoded = try canonicalData(input)
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                )
                object["unexpected_field"] = true
                let data = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
                try writeFixtureData(data, to: inputURL)
            case .extraFile:
                try writeFixture(input, to: inputURL)
                try writeFixtureData(
                    Data("stale".utf8),
                    to: root.appendingPathComponent("stale.json")
                )
            }

            XCTAssertThrowsError(try consumeInput(from: root, now: 101))
        }
    }

    func testProbeResultIsCreateNewAndRedacted() throws {
        let root = try temporaryPrivateDirectory(name: "result")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = ProbeInput.fixture(
            deviceID: "private-device-id-needle",
            clawID: "private-claw-id-needle"
        )
        let result = ProbeResult.failed(input: input)

        let previousUmask = umask(0o377)
        defer { umask(previousUmask) }
        try writeResult(result, to: root)
        let resultURL = root.appendingPathComponent(
            "result-\(input.executionRunID).json"
        )
        let data = try Data(contentsOf: resultURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ProbeResult.expectedKeys)
        XCTAssertEqual(
            object["contract"] as? String,
            "mobile_claw_vpn_dev_e2e_probe_result_v1"
        )
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual(object["reason"] as? String, "control_plane_authorization_failed")
        XCTAssertEqual(object["execution_run_id"] as? String, input.executionRunID)
        XCTAssertEqual(
            object["control_plane_sequence_completed"] as? Bool,
            false
        )
        XCTAssertEqual(object["authorized"] as? Bool, false)
        XCTAssertTrue(object["production_activation_observed"] is NSNull)
        XCTAssertEqual(object["raw_values_printed"] as? Bool, false)
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            data
        )
        XCTAssertFalse(text.contains("private-device-id-needle"))
        XCTAssertFalse(text.contains("private-claw-id-needle"))
        XCTAssertEqual(try mode(of: resultURL), 0o600)
        XCTAssertThrowsError(try writeResult(result, to: root))
    }

    func testProbePassedResultIsExactAndRedacted() throws {
        let root = try temporaryPrivateDirectory(name: "passed-result")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = ProbeInput.fixture(
            deviceID: "private-passed-device-id-needle",
            clawID: "private-passed-claw-id-needle"
        )
        let authorization = ProbeAuthorizationFixture(
            authorized: true,
            productionActivation: false,
            status: ProbeStatusFixture(
                productionActivation: false,
                snapshotPresent: true,
                enrolledDeviceCount: 11,
                availableClawCount: 12,
                grantCount: 13,
                offerCount: 14,
                sessionCount: 15
            )
        )
        let snapshot = ProbeAuthorizationSnapshot(authorization: authorization)
        let result = ProbeResult.passed(input: input, authorization: snapshot)

        let previousUmask = umask(0o377)
        defer { umask(previousUmask) }
        try writeResult(result, to: root)
        let resultURL = root.appendingPathComponent(
            "result-\(input.executionRunID).json"
        )
        let data = try Data(contentsOf: resultURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ProbeResult.expectedKeys)
        XCTAssertEqual(
            object["contract"] as? String,
            "mobile_claw_vpn_dev_e2e_probe_result_v1"
        )
        XCTAssertEqual(object["status"] as? String, "passed")
        XCTAssertTrue(object["reason"] is NSNull)
        XCTAssertEqual(object["execution_run_id"] as? String, input.executionRunID)
        XCTAssertEqual(
            object["control_plane_sequence_completed"] as? Bool,
            true
        )
        XCTAssertEqual(object["authorized"] as? Bool, true)
        XCTAssertEqual(object["production_activation_observed"] as? Bool, false)
        XCTAssertEqual(object["status_snapshot_present"] as? Bool, true)
        XCTAssertEqual(object["enrolled_device_count"] as? Int, 11)
        XCTAssertEqual(object["available_claw_count"] as? Int, 12)
        XCTAssertEqual(object["grant_count"] as? Int, 13)
        XCTAssertEqual(object["offer_count"] as? Int, 14)
        XCTAssertEqual(object["session_count"] as? Int, 15)
        XCTAssertEqual(object["raw_values_printed"] as? Bool, false)
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            data
        )
        XCTAssertFalse(text.contains("private-passed-device-id-needle"))
        XCTAssertFalse(text.contains("private-passed-claw-id-needle"))
        XCTAssertEqual(try mode(of: resultURL), 0o600)
        XCTAssertThrowsError(try writeResult(result, to: root))
    }

    private enum InputVariant: String, CaseIterable {
        case expired
        case ttlTooLong = "ttl-too-long"
        case ttlOverflow = "ttl-overflow"
        case ownerPresenceMissing = "owner-presence-missing"
        case mode
        case extraField = "extra-field"
        case extraFile = "extra-file"
    }

    private enum ProbeError: Error {
        case refused
    }

    private struct ProbeInput: Codable, Equatable {
        static let expectedKeys: Set<String> = [
            "contract", "attempt_id", "readiness_run_id", "artifact_sha",
            "execution_manifest_sha256", "device_binding", "execution_run_id",
            "execution_claim_sha256", "created_at_unix", "expires_at_unix",
            "bundle_id", "device_alias", "claw_alias", "device_id", "claw_id",
            "owner_present_required", "local_biometric_presence_observed",
            "raw_values_printed",
        ]

        var contract: String
        var attemptID: String
        var readinessRunID: String
        var artifactSHA: String
        var executionManifestSHA256: String
        var deviceBinding: String
        var executionRunID: String
        var executionClaimSHA256: String
        var createdAtUnix: Int64
        var expiresAtUnix: Int64
        var bundleID: String
        var deviceAlias: String
        var clawAlias: String
        var deviceID: String
        var clawID: String
        var ownerPresentRequired: Bool
        var localBiometricPresenceObserved: Bool
        var rawValuesPrinted: Bool

        enum CodingKeys: String, CodingKey {
            case contract
            case attemptID = "attempt_id"
            case readinessRunID = "readiness_run_id"
            case artifactSHA = "artifact_sha"
            case executionManifestSHA256 = "execution_manifest_sha256"
            case deviceBinding = "device_binding"
            case executionRunID = "execution_run_id"
            case executionClaimSHA256 = "execution_claim_sha256"
            case createdAtUnix = "created_at_unix"
            case expiresAtUnix = "expires_at_unix"
            case bundleID = "bundle_id"
            case deviceAlias = "device_alias"
            case clawAlias = "claw_alias"
            case deviceID = "device_id"
            case clawID = "claw_id"
            case ownerPresentRequired = "owner_present_required"
            case localBiometricPresenceObserved = "local_biometric_presence_observed"
            case rawValuesPrinted = "raw_values_printed"
        }

        func validate(now: Int64) throws {
            let ttl = expiresAtUnix.subtractingReportingOverflow(createdAtUnix)
            guard contract == "mobile_claw_vpn_dev_e2e_probe_input_v1",
                  Self.isUUID(attemptID),
                  Self.isUUID(readinessRunID),
                  Self.isUUID(executionRunID),
                  Self.isHex(artifactSHA, count: 40),
                  Self.isHex(executionManifestSHA256, count: 64),
                  Self.isHex(deviceBinding, count: 64),
                  Self.isHex(executionClaimSHA256, count: 64),
                  createdAtUnix <= now,
                  expiresAtUnix > now,
                  !ttl.overflow,
                  ttl.partialValue > 0,
                  ttl.partialValue <= maximumInputTTL,
                  bundleID == "com.soyeht.app.dev",
                  deviceAlias == "Device-D",
                  ["Claw-M", "Claw-L"].contains(clawAlias),
                  Self.isPrivateIdentifier(deviceID),
                  Self.isPrivateIdentifier(clawID),
                  ownerPresentRequired,
                  localBiometricPresenceObserved,
                  !rawValuesPrinted else {
                throw ProbeError.refused
            }
        }

        static func fixture(
            deviceID: String = "device-id-fixture",
            clawID: String = "claw-id-fixture"
        ) -> Self {
            Self(
                contract: "mobile_claw_vpn_dev_e2e_probe_input_v1",
                attemptID: "11111111-1111-4111-8111-111111111111",
                readinessRunID: "22222222-2222-4222-8222-222222222222",
                artifactSHA: String(repeating: "a", count: 40),
                executionManifestSHA256: String(repeating: "b", count: 64),
                deviceBinding: String(repeating: "c", count: 64),
                executionRunID: "33333333-3333-4333-8333-333333333333",
                executionClaimSHA256: String(repeating: "d", count: 64),
                createdAtUnix: 100,
                expiresAtUnix: 220,
                bundleID: "com.soyeht.app.dev",
                deviceAlias: "Device-D",
                clawAlias: "Claw-M",
                deviceID: deviceID,
                clawID: clawID,
                ownerPresentRequired: true,
                localBiometricPresenceObserved: true,
                rawValuesPrinted: false
            )
        }

        private static func isUUID(_ value: String) -> Bool {
            UUID(uuidString: value)?.uuidString.lowercased() == value
        }

        private static func isHex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
        }

        private static func isPrivateIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy {
                $0 >= 0x20 && $0 != 0x7f
            }
        }
    }

    private struct ProbeAuthorizationSnapshot {
        var authorized: Bool
        var productionActivationObserved: Bool
        var statusSnapshotPresent: Bool
        var enrolledDeviceCount: Int
        var availableClawCount: Int
        var grantCount: Int
        var offerCount: Int
        var sessionCount: Int

        init<Authorization: ProbeAuthorizationSource>(authorization: Authorization) {
            authorized = authorization.authorized
            productionActivationObserved = authorization.productionActivation ||
                authorization.status.productionActivation
            statusSnapshotPresent = authorization.status.snapshotPresent
            enrolledDeviceCount = authorization.status.enrolledDeviceCount
            availableClawCount = authorization.status.availableClawCount
            grantCount = authorization.status.grantCount
            offerCount = authorization.status.offerCount
            sessionCount = authorization.status.sessionCount
        }
    }

    private struct ProbeStatusFixture: ProbeStatusSource {
        var productionActivation: Bool
        var snapshotPresent: Bool
        var enrolledDeviceCount: Int
        var availableClawCount: Int
        var grantCount: Int
        var offerCount: Int
        var sessionCount: Int
    }

    private struct ProbeAuthorizationFixture: ProbeAuthorizationSource {
        var authorized: Bool
        var productionActivation: Bool
        var status: ProbeStatusFixture
    }

    private struct ProbeResult: Encodable {
        static let expectedKeys: Set<String> = [
            "contract", "status", "reason", "attempt_id", "readiness_run_id",
            "artifact_sha", "execution_manifest_sha256", "device_binding",
            "execution_run_id", "execution_claim_sha256", "bundle_id",
            "device_alias", "claw_alias", "control_plane_sequence_completed",
            "authorized", "production_activation_observed", "status_snapshot_present",
            "enrolled_device_count", "available_claw_count", "grant_count",
            "offer_count", "session_count", "raw_values_printed",
        ]

        var contract: String
        var status: String
        var reason: String?
        var attemptID: String
        var readinessRunID: String
        var artifactSHA: String
        var executionManifestSHA256: String
        var deviceBinding: String
        var executionRunID: String
        var executionClaimSHA256: String
        var bundleID: String
        var deviceAlias: String
        var clawAlias: String
        var controlPlaneSequenceCompleted: Bool
        var authorized: Bool
        var productionActivationObserved: Bool?
        var statusSnapshotPresent: Bool
        var enrolledDeviceCount: Int
        var availableClawCount: Int
        var grantCount: Int
        var offerCount: Int
        var sessionCount: Int
        var rawValuesPrinted: Bool

        enum CodingKeys: String, CodingKey {
            case contract, status, reason, authorized
            case attemptID = "attempt_id"
            case readinessRunID = "readiness_run_id"
            case artifactSHA = "artifact_sha"
            case executionManifestSHA256 = "execution_manifest_sha256"
            case deviceBinding = "device_binding"
            case executionRunID = "execution_run_id"
            case executionClaimSHA256 = "execution_claim_sha256"
            case bundleID = "bundle_id"
            case deviceAlias = "device_alias"
            case clawAlias = "claw_alias"
            case controlPlaneSequenceCompleted = "control_plane_sequence_completed"
            case productionActivationObserved = "production_activation_observed"
            case statusSnapshotPresent = "status_snapshot_present"
            case enrolledDeviceCount = "enrolled_device_count"
            case availableClawCount = "available_claw_count"
            case grantCount = "grant_count"
            case offerCount = "offer_count"
            case sessionCount = "session_count"
            case rawValuesPrinted = "raw_values_printed"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(contract, forKey: .contract)
            try container.encode(status, forKey: .status)
            if let reason {
                try container.encode(reason, forKey: .reason)
            } else {
                try container.encodeNil(forKey: .reason)
            }
            try container.encode(attemptID, forKey: .attemptID)
            try container.encode(readinessRunID, forKey: .readinessRunID)
            try container.encode(artifactSHA, forKey: .artifactSHA)
            try container.encode(executionManifestSHA256, forKey: .executionManifestSHA256)
            try container.encode(deviceBinding, forKey: .deviceBinding)
            try container.encode(executionRunID, forKey: .executionRunID)
            try container.encode(executionClaimSHA256, forKey: .executionClaimSHA256)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(deviceAlias, forKey: .deviceAlias)
            try container.encode(clawAlias, forKey: .clawAlias)
            try container.encode(
                controlPlaneSequenceCompleted,
                forKey: .controlPlaneSequenceCompleted
            )
            try container.encode(authorized, forKey: .authorized)
            if let productionActivationObserved {
                try container.encode(
                    productionActivationObserved,
                    forKey: .productionActivationObserved
                )
            } else {
                try container.encodeNil(forKey: .productionActivationObserved)
            }
            try container.encode(statusSnapshotPresent, forKey: .statusSnapshotPresent)
            try container.encode(enrolledDeviceCount, forKey: .enrolledDeviceCount)
            try container.encode(availableClawCount, forKey: .availableClawCount)
            try container.encode(grantCount, forKey: .grantCount)
            try container.encode(offerCount, forKey: .offerCount)
            try container.encode(sessionCount, forKey: .sessionCount)
            try container.encode(rawValuesPrinted, forKey: .rawValuesPrinted)
        }

        static func passed(
            input: ProbeInput,
            authorization: ProbeAuthorizationSnapshot
        ) -> Self {
            Self(
                contract: "mobile_claw_vpn_dev_e2e_probe_result_v1",
                status: "passed",
                reason: nil,
                attemptID: input.attemptID,
                readinessRunID: input.readinessRunID,
                artifactSHA: input.artifactSHA,
                executionManifestSHA256: input.executionManifestSHA256,
                deviceBinding: input.deviceBinding,
                executionRunID: input.executionRunID,
                executionClaimSHA256: input.executionClaimSHA256,
                bundleID: input.bundleID,
                deviceAlias: input.deviceAlias,
                clawAlias: input.clawAlias,
                controlPlaneSequenceCompleted: true,
                authorized: authorization.authorized,
                productionActivationObserved: authorization.productionActivationObserved,
                statusSnapshotPresent: authorization.statusSnapshotPresent,
                enrolledDeviceCount: authorization.enrolledDeviceCount,
                availableClawCount: authorization.availableClawCount,
                grantCount: authorization.grantCount,
                offerCount: authorization.offerCount,
                sessionCount: authorization.sessionCount,
                rawValuesPrinted: false
            )
        }

        static func failed(input: ProbeInput) -> Self {
            Self(
                contract: "mobile_claw_vpn_dev_e2e_probe_result_v1",
                status: "failed",
                reason: "control_plane_authorization_failed",
                attemptID: input.attemptID,
                readinessRunID: input.readinessRunID,
                artifactSHA: input.artifactSHA,
                executionManifestSHA256: input.executionManifestSHA256,
                deviceBinding: input.deviceBinding,
                executionRunID: input.executionRunID,
                executionClaimSHA256: input.executionClaimSHA256,
                bundleID: input.bundleID,
                deviceAlias: input.deviceAlias,
                clawAlias: input.clawAlias,
                controlPlaneSequenceCompleted: false,
                authorized: false,
                productionActivationObserved: nil,
                statusSnapshotPresent: false,
                enrolledDeviceCount: 0,
                availableClawCount: 0,
                grantCount: 0,
                offerCount: 0,
                sessionCount: 0,
                rawValuesPrinted: false
            )
        }
    }

    private func consumeInput(from directory: URL, now: Int64) throws -> ProbeInput {
        try requireDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard entries.map(\.lastPathComponent) == [Self.inputName] else {
            throw ProbeError.refused
        }

        let inputURL = directory.appendingPathComponent(Self.inputName)
        let descriptor = open(inputURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProbeError.refused }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o600,
              metadata.st_nlink == 1,
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumFileBytes else {
            throw ProbeError.refused
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard unlink(inputURL.path) == 0 else { throw ProbeError.refused }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw ProbeError.refused }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw ProbeError.refused }

        let input: ProbeInput = try decodeCanonical(
            data,
            expectedKeys: ProbeInput.expectedKeys
        )
        try input.validate(now: now)
        return input
    }

    private func writeResult(_ result: ProbeResult, to directory: URL) throws {
        try requireDirectory(directory)
        let data = try canonicalData(result)
        let resultURL = directory.appendingPathComponent(
            "result-\(result.executionRunID).json"
        )
        try atomicCreate(data, at: resultURL)
    }

    private func decodeCanonical<Value: Decodable>(
        _ data: Data,
        expectedKeys: Set<String>
    ) throws -> Value {
        guard !data.isEmpty,
              data.count <= Int(Self.maximumFileBytes),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expectedKeys,
              try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) == data else {
            throw ProbeError.refused
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func atomicCreate(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw ProbeError.refused }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary { unlink(temporary.path) }
        }
        guard fchmod(descriptor, 0o600) == 0,
              data.withUnsafeBytes({ bytes in
                  guard let base = bytes.baseAddress else { return false }
                  var written = 0
                  while written < bytes.count {
                      let count = Darwin.write(
                          descriptor,
                          base.advanced(by: written),
                          bytes.count - written
                      )
                      guard count > 0 else { return false }
                      written += count
                  }
                  return true
              }),
              fsync(descriptor) == 0 else {
            throw ProbeError.refused
        }
        guard link(temporary.path, url.path) == 0 else { throw ProbeError.refused }
        guard unlink(temporary.path) == 0 else { throw ProbeError.refused }
        removeTemporary = false
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw ProbeError.refused }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw ProbeError.refused }
    }

    private func requireDirectory(_ directory: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o700 else {
            throw ProbeError.refused
        }
    }

    private func probeDirectory() throws -> URL {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        return documents.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func temporaryPrivateDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "soyeht-mobile-claw-vpn-probe-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        guard chmod(directory.path, 0o700) == 0 else { throw ProbeError.refused }
        return directory
    }

    private func writeFixture(_ input: ProbeInput, to url: URL) throws {
        try writeFixtureData(try canonicalData(input), to: url)
    }

    private func writeFixtureData(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data),
              chmod(url.path, 0o600) == 0 else {
            throw ProbeError.refused
        }
    }

    private func mode(of url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw ProbeError.refused }
        return metadata.st_mode & 0o777
    }

    private func currentTime() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
