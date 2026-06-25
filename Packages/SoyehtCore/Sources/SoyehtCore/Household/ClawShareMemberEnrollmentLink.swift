import Foundation

public enum ClawShareMemberEnrollmentLinkError: Error, Equatable, Sendable {
    case malformed
    case invalidBinding
}

public enum ClawShareMemberEnrollmentLink {
    public static let scheme = "soyeht"
    public static let host = "claw-share"
    public static let path = "/member-device/v1"
    public static let bindingQueryItem = "b"

    public static var prefix: String {
        var components = baseComponents()
        components.queryItems = [URLQueryItem(name: bindingQueryItem, value: "")]
        return components.string ?? ""
    }

    public static func qrPayload(for binding: MemberDeviceBinding) -> String {
        var components = baseComponents()
        components.queryItems = [
            URLQueryItem(
                name: bindingQueryItem,
                value: PairingCrypto.base64URLEncode(binding.canonicalBytes())
            )
        ]
        guard let value = components.string else {
            preconditionFailure("member enrollment link components must be representable")
        }
        return value
    }

    public static func copyString(for binding: MemberDeviceBinding) -> String {
        qrPayload(for: binding)
    }

    public static func decode(_ raw: String) throws -> MemberDeviceBinding {
        let binding = try decodeUnverified(raw)
        do {
            try binding.verify()
        } catch {
            throw ClawShareMemberEnrollmentLinkError.invalidBinding
        }
        return binding
    }

    static func decodeUnverified(_ raw: String) throws -> MemberDeviceBinding {
        let encoded = try encodedBinding(from: raw)
        guard let bytes = decodeBase64URLNoPadding(encoded) else {
            throw ClawShareMemberEnrollmentLinkError.malformed
        }
        do {
            return try MemberDeviceBinding.fromCanonicalBytes(bytes)
        } catch {
            throw ClawShareMemberEnrollmentLinkError.malformed
        }
    }

    private static func encodedBinding(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClawShareMemberEnrollmentLinkError.malformed }

        if let components = URLComponents(string: trimmed),
           components.scheme != nil
        {
            guard components.scheme == scheme,
                  components.host == host,
                  components.path == path,
                  components.fragment == nil,
                  let queryItems = components.queryItems,
                  queryItems.count == 1,
                  queryItems[0].name == bindingQueryItem,
                  let value = queryItems[0].value
            else {
                throw ClawShareMemberEnrollmentLinkError.malformed
            }
            return value
        }

        return trimmed
    }

    private static func baseComponents() -> URLComponents {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        return components
    }

    private static func decodeBase64URLNoPadding(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return PairingCrypto.base64URLDecode(value)
    }
}
