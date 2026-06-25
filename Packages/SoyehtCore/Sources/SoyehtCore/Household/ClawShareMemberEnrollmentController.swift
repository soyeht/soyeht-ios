import Foundation

public enum ClawShareMemberEnrollmentControllerError: Error, Equatable, Sendable {
    case invalidEnrollmentLink(ClawShareMemberEnrollmentLinkError)
    case fingerprintUnavailable
}

public struct EnrollableMember: Equatable, Sendable {
    public let memberId: String
    public let fingerprintWords: [String]
    public let fingerprintDisplay: String
    public let binding: MemberDeviceBinding

    public init(
        memberId: String,
        fingerprintWords: [String],
        fingerprintDisplay: String,
        binding: MemberDeviceBinding
    ) {
        self.memberId = memberId
        self.fingerprintWords = fingerprintWords
        self.fingerprintDisplay = fingerprintDisplay
        self.binding = binding
    }
}

public struct ClawShareMemberEnrollmentController: Sendable {
    private let wordlist: BIP39Wordlist

    public init(wordlist: BIP39Wordlist) {
        self.wordlist = wordlist
    }

    public init() throws {
        self.wordlist = try BIP39Wordlist()
    }

    /// Pure owner-side preview for scanner/paste input. It verifies the member binding and
    /// derives display-only trust material; enrollment still requires an explicit owner action.
    public func prepare(rawInput: String) throws -> EnrollableMember {
        let binding: MemberDeviceBinding
        do {
            binding = try ClawShareMemberEnrollmentLink.decode(rawInput)
        } catch let error as ClawShareMemberEnrollmentLinkError {
            throw ClawShareMemberEnrollmentControllerError.invalidEnrollmentLink(error)
        } catch {
            throw ClawShareMemberEnrollmentControllerError.invalidEnrollmentLink(.malformed)
        }

        let fingerprint: OperatorFingerprint
        do {
            fingerprint = try OperatorFingerprint.derive(
                machinePublicKey: binding.memberPublicKey,
                wordlist: wordlist
            )
        } catch {
            throw ClawShareMemberEnrollmentControllerError.fingerprintUnavailable
        }

        return EnrollableMember(
            memberId: binding.memberId,
            fingerprintWords: fingerprint.words,
            fingerprintDisplay: fingerprint.words.joined(separator: " "),
            binding: binding
        )
    }
}
