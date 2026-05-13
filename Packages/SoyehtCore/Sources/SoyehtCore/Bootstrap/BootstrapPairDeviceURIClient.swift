import Foundation

/// Client for `GET /bootstrap/pair-device-uri`.
///
/// This is the Mac-first, no-QR bridge: once a house has been named and the
/// engine is waiting for the first iPhone, trusted setup discovery can request
/// the current first-owner pairing URI and deliver it directly to the iPhone.
public struct BootstrapPairDeviceURIClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/pair-device-uri"

    private static let requiredKeys: Set<String> = [
        "v", "house_name", "host_label", "hh_id", "hh_pub", "pair_device_uri",
    ]
    private static let knownKeys: Set<String> = requiredKeys.union(["expires_at"])

    private let baseURL: URL
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    public func fetch() async throws -> BootstrapPairDeviceURIResponse {
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        let data = try await BootstrapWire.send(
            method: "GET",
            url: url,
            body: nil,
            authorization: nil,
            perform: perform
        )
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> BootstrapPairDeviceURIResponse {
        guard case .map(let map) = try BootstrapWire.decodeCanonical(data) else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        do {
            try HouseholdCBORMapKeys.requireRequired(map, keys: requiredKeys)
            try HouseholdCBORMapKeys.requireKnown(map, keys: knownKeys)
        } catch {
            throw BootstrapError.protocolViolation(detail: .missingRequiredField)
        }
        guard case .unsigned(1) = map["v"] else {
            throw BootstrapError.protocolViolation(detail: .unsupportedEnvelopeVersion(
                (map["v"].flatMap { if case .unsigned(let u) = $0 { u } else { nil } }) ?? 0
            ))
        }
        guard case .text(let houseName) = map["house_name"],
              case .text(let hostLabel) = map["host_label"],
              case .text(let hhId) = map["hh_id"],
              case .bytes(let hhPub) = map["hh_pub"],
              case .text(let pairDeviceURI) = map["pair_device_uri"],
              hhPub.count == 33 else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }

        let expiresAt: UInt64?
        if let expiresValue = map["expires_at"] {
            guard case .unsigned(let value) = expiresValue else {
                throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
            }
            expiresAt = value
        } else {
            expiresAt = nil
        }

        return BootstrapPairDeviceURIResponse(
            version: 1,
            houseName: houseName,
            hostLabel: hostLabel,
            hhId: hhId,
            hhPub: hhPub,
            pairDeviceURI: pairDeviceURI,
            expiresAt: expiresAt
        )
    }
}
