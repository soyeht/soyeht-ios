import Foundation

public struct RosterSignerPinResponse: Sendable, Equatable {
    public let v: UInt64
    public let clientNonce: Data
    public let hhId: String
    public let mId: String
    public let machineCert: Data
    public let machineCertFingerprint: Data
    public let signature: Data
}

public enum RosterSignerPinClientError: Error, Equatable, Sendable {
    case wire(RosterWireError)
    case httpStatus(Int)
    case transportFailed
}

public struct RosterSignerPinClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/api/v1/household/roster/signer-pin"

    private let baseURL: URL
    private let popSigner: HouseholdPoPSigner
    private let perform: TransportPerform

    public init(baseURL: URL, popSigner: HouseholdPoPSigner, perform: @escaping TransportPerform) {
        self.baseURL = baseURL
        self.popSigner = popSigner
        self.perform = perform
    }

    public func signerPin(clientNonce: Data) async throws -> RosterSignerPinResponse {
        let (url, pathAndQuery) = try RosterWire.endpointURL(baseURL: baseURL, path: Self.path)
        guard clientNonce.count == 32 else {
            throw RosterSignerPinClientError.wire(.malformedResponse)
        }
        let body = try RosterWire.encodeNonceRequest(clientNonce: clientNonce)
        guard body.count <= RosterWire.nonceBodyLimit else {
            throw RosterSignerPinClientError.wire(.payloadTooLarge)
        }
        let authorization = try popSigner.authorization(
            method: "POST",
            pathAndQuery: pathAndQuery,
            body: body
        ).authorizationHeader

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(RosterWire.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch {
            throw RosterSignerPinClientError.transportFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw RosterSignerPinClientError.transportFailed
        }
        try RosterWire.validateResponseContentType(http.value(forHTTPHeaderField: "Content-Type"))
        guard http.statusCode == 200 else {
            throw RosterSignerPinClientError.wire(
                RosterClientErrorEnvelope.decodeError(status: http.statusCode, data: data)
            )
        }
        let decoded = try RosterWire.decodeCanonical(data)
        guard case .map(let map) = decoded else {
            throw RosterSignerPinClientError.wire(.unexpectedKeySet)
        }
        try RosterWire.requireExactKeys(map, [
            "client_nonce", "hh_id", "m_id", "machine_cert",
            "machine_cert_fingerprint", "signature", "v",
        ])
        let v = try RosterWire.requireUInt(map, "v")
        guard v == 1 else { throw RosterSignerPinClientError.wire(.malformedResponse) }
        let machineCert = try RosterWire.requireBytes(map, "machine_cert")
        guard !machineCert.isEmpty else { throw RosterSignerPinClientError.wire(.malformedResponse) }
        return RosterSignerPinResponse(
            v: v,
            clientNonce: try RosterWire.requireBytes32(map, "client_nonce"),
            hhId: try RosterWire.requireText(map, "hh_id"),
            mId: try RosterWire.requireText(map, "m_id"),
            machineCert: machineCert,
            machineCertFingerprint: try RosterWire.requireBytes32(map, "machine_cert_fingerprint"),
            signature: try RosterWire.requireBytes64(map, "signature")
        )
    }
}
