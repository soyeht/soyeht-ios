import CryptoKit
import Foundation

@main
enum LocalPresenceSelfTest {
    static func main() throws {
        func fixture(
            contract: String = challengeContract,
            attemptID: String = "11111111-1111-4111-8111-111111111111",
            readinessRunID: String = "22222222-2222-4222-8222-222222222222",
            artifactSHA: String = String(repeating: "a", count: 40),
            executionManifestSHA256: String = String(repeating: "b", count: 64),
            deviceBinding: String = String(repeating: "c", count: 64),
            executionRunID: String = "33333333-3333-4333-8333-333333333333",
            replayNonce: String = String(repeating: "d", count: 64),
            createdAtUnix: Int64 = 100,
            expiresAtUnix: Int64 = 220,
            bundleID: String = "com.soyeht.app.dev",
            deviceAlias: String = "Device-D",
            clawAlias: String = "Claw-M",
            ownerPresentRequired: Bool = true,
            rawValuesPrinted: Bool = false
        ) -> LocalPresenceChallenge {
            LocalPresenceChallenge(
                contract: contract,
                attemptID: attemptID,
                readinessRunID: readinessRunID,
                artifactSHA: artifactSHA,
                executionManifestSHA256: executionManifestSHA256,
                deviceBinding: deviceBinding,
                executionRunID: executionRunID,
                replayNonce: replayNonce,
                createdAtUnix: createdAtUnix,
                expiresAtUnix: expiresAtUnix,
                bundleID: bundleID,
                deviceAlias: deviceAlias,
                clawAlias: clawAlias,
                ownerPresentRequired: ownerPresentRequired,
                rawValuesPrinted: rawValuesPrinted
            )
        }

        func encode(_ challenge: LocalPresenceChallenge) throws -> Data {
            let encoded = try JSONEncoder().encode(challenge)
            let object = try JSONSerialization.jsonObject(with: encoded)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        func clock(_ values: [Int64]) -> LocalPresenceEngine.Clock {
            var remaining = values
            return {
                guard !remaining.isEmpty else { return values.last ?? 0 }
                return remaining.removeFirst()
            }
        }

        func expect(
            _ expected: LocalPresenceError,
            _ operation: () throws -> Void
        ) throws {
            do {
                try operation()
            } catch let error as LocalPresenceError {
                guard error == expected else { throw LocalPresenceError.inputInvalid }
                return
            }
            throw LocalPresenceError.inputInvalid
        }

        let challenge = fixture()
        let encoded = try encode(challenge)
        let expectedDigest = challenge.digest()
        guard hex(expectedDigest) ==
            "2c34df4c2981fbd2119c1377e1f2d9dbbfa9e69234f04b3b650c24cf621b3593" else {
            throw LocalPresenceError.inputInvalid
        }
        let key = P256.Signing.PrivateKey()
        var observeCalled = false
        let result = try LocalPresenceEngine.execute(
            input: encoded,
            clock: clock([101, 102])
        ) { observed, digest in
            observeCalled = true
            guard observed == challenge, digest == expectedDigest else { return false }
            let signature = try key.signature(for: digest)
            return key.publicKey.isValidSignature(signature, for: digest)
        }
        guard observeCalled,
              result.status == "local_biometric_presence_observed",
              result.challengeSHA256 == hex(challenge.digest()),
              result.executionRunID == challenge.executionRunID,
              result.localBiometricPresenceObserved,
              !result.ownerAuthenticated,
              !result.executionAuthorized,
              !result.appLaunchAttempted,
              !result.rawValuesPrinted else {
            throw LocalPresenceError.inputInvalid
        }

        let signature = try key.signature(for: challenge.digest())
        let mutations = [
            fixture(contract: challengeContract + "-changed"),
            fixture(attemptID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            fixture(readinessRunID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            fixture(artifactSHA: String(repeating: "e", count: 40)),
            fixture(executionManifestSHA256: String(repeating: "e", count: 64)),
            fixture(deviceBinding: String(repeating: "e", count: 64)),
            fixture(executionRunID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
            fixture(replayNonce: String(repeating: "e", count: 64)),
            fixture(createdAtUnix: 101),
            fixture(expiresAtUnix: 219),
            fixture(bundleID: "com.soyeht.app"),
            fixture(deviceAlias: ""),
            fixture(clawAlias: ""),
            fixture(ownerPresentRequired: false),
            fixture(rawValuesPrinted: true),
        ]
        for changed in mutations {
            guard !key.publicKey.isValidSignature(signature, for: changed.digest()) else {
                throw LocalPresenceError.inputInvalid
            }
        }

        let invalidChallenges = [
            fixture(executionRunID: "44444444-4444-4444-8444-444444444444", expiresAtUnix: 101),
            fixture(executionRunID: "55555555-5555-4555-8555-555555555555", expiresAtUnix: 221),
            fixture(executionRunID: "66666666-6666-4666-8666-666666666666", createdAtUnix: 102),
            fixture(executionRunID: "77777777-7777-4777-8777-777777777777", ownerPresentRequired: false),
            fixture(executionRunID: "88888888-8888-4888-8888-888888888888", rawValuesPrinted: true),
            fixture(
                executionRunID: "99999999-9999-4999-8999-999999999999",
                createdAtUnix: .min,
                expiresAtUnix: .max
            ),
        ]
        for invalid in invalidChallenges {
            try expect(.challengeInvalid) {
                _ = try LocalPresenceEngine.execute(
                    input: encode(invalid),
                    clock: clock([101, 102])
                ) { _, _ in true }
            }
        }

        try expect(.challengeInvalid) {
            _ = try LocalPresenceEngine.execute(
                input: encoded,
                clock: clock([101, 220])
            ) { _, _ in true }
        }
        try expect(.localBiometricPresenceFailed) {
            _ = try LocalPresenceEngine.execute(
                input: encoded,
                clock: clock([101, 102])
            ) { _, _ in false }
        }

        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw LocalPresenceError.inputInvalid
        }
        object["unexpected_field"] = true
        let extra = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try expect(.inputInvalid) {
            _ = try LocalPresenceEngine.execute(
                input: extra,
                clock: clock([101, 102])
            ) { _, _ in true }
        }
        var noncanonical = encoded
        noncanonical.append(0x0A)
        try expect(.inputInvalid) {
            _ = try LocalPresenceEngine.execute(
                input: noncanonical,
                clock: clock([101, 102])
            ) { _, _ in true }
        }
        try expect(.inputInvalid) {
            _ = try LocalPresenceEngine.execute(
                input: Data(repeating: 0x20, count: maximumInputBytes + 1),
                clock: clock([101, 102])
            ) { _, _ in true }
        }

        print("local presence self-test passed")
    }
}
