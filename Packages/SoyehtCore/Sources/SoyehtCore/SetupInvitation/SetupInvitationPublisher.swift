import Foundation
import Network

/// iPhone-side Bonjour publisher for `_soyeht-setup._tcp.` (Caso B, FR-040).
///
/// Publishes the setup invitation as a TXT record `m=<base64url(CBOR)>` over the
/// Tailscale interface only. Plain LAN publication is opt-in per network (FR-041).
/// Use `NWParameters.requiredInterfaceType = .other` to restrict to Tailscale
/// (tun/utun interfaces, not .wifi or .cellular).
///
/// Lifecycle:
/// 1. Call `start()` after user confirms "Sim, estou no Mac" (cena PB2).
/// 2. Mac discovers the service, claims the token via `/bootstrap/claim-setup-invitation`.
/// 3. Call `stop()` after successful claim (or TTL expiry, or user cancels).
public final class SetupInvitationPublisher: @unchecked Sendable {
    public static let directPort: UInt16 = 8092

    public enum State: Equatable, Sendable {
        case idle
        case publishing
        case failed(String)
        case stopped
    }

    private let invitation: SetupInvitationPayload
    private let parameters: NWParameters
    private let directPort: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.soyeht.setup-invitation.publisher")

    private var _state: State = .idle
    public private(set) var state: State {
        get { _state }
        set { _state = newValue; onStateChange?(newValue) }
    }

    /// Called on the publisher's internal queue when `state` changes.
    public var onStateChange: (@Sendable (State) -> Void)?
    /// Called when a Mac reaches this iPhone directly over Tailscale and reports
    /// the engine URL the iPhone should use for bootstrap naming. The same
    /// short-lived callback can include local Mac pairing material so the iPhone
    /// can show panes/workspaces immediately after naming.
    public var onMacClaimed: (@Sendable (SetupInvitationDirectClaim) -> Void)?

    public init(
        invitation: SetupInvitationPayload,
        parameters: NWParameters = .tailscaleOnly(),
        directPort: UInt16 = SetupInvitationPublisher.directPort
    ) {
        self.invitation = invitation
        self.parameters = parameters
        self.directPort = directPort
    }

    /// Starts publishing the Bonjour service. Safe to call from any thread.
    public func start() {
        queue.async { self._start() }
    }

    /// Stops the service and cancels the underlying `NWListener`.
    public func stop() {
        queue.async { self._stop() }
    }

    // MARK: - Private

    private func _start() {
        guard _state == .idle || _state == .stopped else { return }

        let txtRecord: NWTXTRecord
        do {
            txtRecord = NWTXTRecord(try invitation.txtRecordFields())
        } catch {
            state = .failed("TXT encode failed: \(error)")
            return
        }

        let listener: NWListener
        do {
            let port = NWEndpoint.Port(rawValue: directPort) ?? .any
            listener = try NWListener(using: parameters, on: port)
        } catch {
            state = .failed("NWListener init failed: \(error)")
            return
        }

        listener.service = NWListener.Service(
            name: nil,
            type: "_soyeht-setup._tcp.",
            domain: nil,
            txtRecord: txtRecord
        )

        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self.queue.async {
                switch newState {
                case .ready:
                    self.state = .publishing
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .stopped
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.receiveHTTPRequest(on: connection)
            connection.start(queue: self.queue)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    private func _stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let request = DirectHTTPRequest.parse(nextBuffer) {
                self.handle(request, on: connection)
                return
            }
            if isComplete || error != nil {
                self.send(status: 400, body: Data(), contentType: "application/json", on: connection)
                return
            }
            self.receiveHTTPRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: DirectHTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", SetupInvitationDirectEndpoint.invitationPath):
            do {
                let body = try invitation.directEndpointData()
                send(status: 200, body: body, contentType: "application/json", on: connection)
            } catch {
                send(status: 500, body: Data(), contentType: "application/json", on: connection)
            }
        case ("POST", SetupInvitationDirectEndpoint.verifyPath):
            let body = invitation.verifyData()
            send(status: 200, body: body, contentType: "application/cbor", on: connection)
        case ("POST", SetupInvitationDirectEndpoint.claimedPath):
            do {
                let notification = try SetupInvitationDirectClaim.decode(
                    request.body,
                    expectedToken: invitation.token
                )
                onMacClaimed?(notification)
                send(status: 204, body: Data(), contentType: "application/json", on: connection)
            } catch SetupInvitationDirectError.unauthorizedClaim {
                send(status: 401, body: Data(), contentType: "application/json", on: connection)
            } catch {
                send(status: 400, body: Data(), contentType: "application/json", on: connection)
            }
        default:
            send(status: 404, body: Data(), contentType: "application/json", on: connection)
        }
    }

    private func send(status: Int, body: Data, contentType: String, on connection: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 401: reason = "Unauthorized"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Internal Server Error"
        }
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - SetupInvitationPayload

/// The invitation data published in the Bonjour TXT record `m`.
public struct SetupInvitationPayload: Equatable, Sendable {
    public let token: SetupInvitationToken
    public let ownerDisplayName: String?
    /// Unix seconds; MAX `now + 3600`.
    public let expiresAt: UInt64
    /// iPhone APNs device token for Mac to push "casa nasceu".
    public let iphoneApnsToken: Data?
    public let iphoneDeviceID: UUID?
    public let iphoneDeviceName: String?
    public let iphoneDeviceModel: String?

    public init(
        token: SetupInvitationToken,
        ownerDisplayName: String?,
        expiresAt: UInt64,
        iphoneApnsToken: Data?,
        iphoneDeviceID: UUID? = nil,
        iphoneDeviceName: String? = nil,
        iphoneDeviceModel: String? = nil
    ) {
        self.token = token
        self.ownerDisplayName = ownerDisplayName
        self.expiresAt = expiresAt
        self.iphoneApnsToken = iphoneApnsToken
        self.iphoneDeviceID = iphoneDeviceID
        self.iphoneDeviceName = iphoneDeviceName
        self.iphoneDeviceModel = iphoneDeviceModel
    }

    /// Encodes the payload as CBOR then base64url for the TXT `m` key.
    func encodedTXTValue() throws -> String {
        let cbor = encodeCBOR()
        return cbor.base64URLEncodedString()
    }

    func txtRecordFields() throws -> [String: String] {
        var fields: [String: String] = [
            "m": try encodedTXTValue(),
            "v": "1",
            "token": PairingCrypto.base64URLEncode(token.bytes),
            "expires_at": String(expiresAt),
            "owner_display_name": ownerDisplayName ?? "",
            "hh_id": "",
            "setup_role": "iphone",
        ]
        if let iphoneApnsToken {
            fields["iphone_apns_token"] = PairingCrypto.base64URLEncode(iphoneApnsToken)
        }
        if let iphoneDeviceID {
            fields["iphone_device_id"] = iphoneDeviceID.uuidString
        }
        if let iphoneDeviceName {
            fields["iphone_device_name"] = iphoneDeviceName
        }
        if let iphoneDeviceModel {
            fields["iphone_device_model"] = iphoneDeviceModel
        }
        return fields
    }

    func encodeCBOR() -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "token": .bytes(token.bytes),
            "expires_at": .unsigned(expiresAt),
        ]
        map["owner_display_name"] = ownerDisplayName.map { .text($0) } ?? .null
        map["iphone_apns_token"] = iphoneApnsToken.map { .bytes($0) } ?? .null
        map["iphone_device_id"] = iphoneDeviceID.map { .text($0.uuidString) } ?? .null
        map["iphone_device_name"] = iphoneDeviceName.map { .text($0) } ?? .null
        map["iphone_device_model"] = iphoneDeviceModel.map { .text($0) } ?? .null
        return HouseholdCBOR.encode(.map(map))
    }

    public func directEndpointData() throws -> Data {
        let envelope = SetupInvitationDirectEnvelope(
            version: 1,
            token: PairingCrypto.base64URLEncode(token.bytes),
            ownerDisplayName: ownerDisplayName,
            expiresAt: expiresAt,
            iphoneApnsToken: iphoneApnsToken.map(PairingCrypto.base64URLEncode),
            iphoneDeviceID: iphoneDeviceID?.uuidString,
            iphoneDeviceName: iphoneDeviceName,
            iphoneDeviceModel: iphoneDeviceModel
        )
        return try JSONEncoder().encode(envelope)
    }

    public func verifyData() -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "token": .bytes(token.bytes),
            "expires_at": .unsigned(expiresAt),
        ]
        map["owner_display_name"] = ownerDisplayName.map { .text($0) } ?? .null
        map["iphone_apns_token"] = iphoneApnsToken.map { .bytes($0) } ?? .null
        return HouseholdCBOR.encode(.map(map))
    }

    public static func decodeDirectEndpointData(_ data: Data) throws -> SetupInvitationPayload {
        let envelope = try JSONDecoder().decode(SetupInvitationDirectEnvelope.self, from: data)
        guard envelope.version == 1,
              envelope.expiresAt > UInt64(Date().timeIntervalSince1970),
              let tokenBytes = PairingCrypto.base64URLDecode(envelope.token) else {
            throw SetupInvitationDirectError.invalidEnvelope
        }
        let apnsToken = envelope.iphoneApnsToken.flatMap(PairingCrypto.base64URLDecode)
        return SetupInvitationPayload(
            token: try SetupInvitationToken(bytes: tokenBytes),
            ownerDisplayName: envelope.ownerDisplayName,
            expiresAt: envelope.expiresAt,
            iphoneApnsToken: apnsToken,
            iphoneDeviceID: envelope.iphoneDeviceID.flatMap(UUID.init(uuidString:)),
            iphoneDeviceName: envelope.iphoneDeviceName,
            iphoneDeviceModel: envelope.iphoneDeviceModel
        )
    }
}

public enum SetupInvitationDirectEndpoint {
    public static let invitationPath = "/setup-invitation"
    public static let verifyPath = "/setup/verify"
    public static let claimedPath = "/setup-invitation/claimed"
}

public struct SetupInvitationMacLocalPairing: Equatable, Sendable {
    public let macID: UUID
    public let macName: String
    public let host: String
    public let presencePort: Int
    public let attachPort: Int
    public let secret: Data

    public init(
        macID: UUID,
        macName: String,
        host: String,
        presencePort: Int,
        attachPort: Int,
        secret: Data
    ) {
        self.macID = macID
        self.macName = macName
        self.host = host
        self.presencePort = presencePort
        self.attachPort = attachPort
        self.secret = secret
    }
}

public struct SetupInvitationDirectClaim: Equatable, Sendable {
    public let token: SetupInvitationToken
    public let macEngineURL: URL
    public let macLocalPairing: SetupInvitationMacLocalPairing?

    public init(
        token: SetupInvitationToken,
        macEngineURL: URL,
        macLocalPairing: SetupInvitationMacLocalPairing? = nil
    ) {
        self.token = token
        self.macEngineURL = macEngineURL
        self.macLocalPairing = macLocalPairing
    }

    public func encodedData() throws -> Data {
        let localPairing = macLocalPairing.map { pairing in
            MacLocalPairingEnvelope(
                macID: pairing.macID.uuidString,
                macName: pairing.macName,
                host: pairing.host,
                presencePort: pairing.presencePort,
                attachPort: pairing.attachPort,
                secret: PairingCrypto.base64URLEncode(pairing.secret)
            )
        }
        let envelope = Envelope(
            token: PairingCrypto.base64URLEncode(token.bytes),
            macEngineURL: macEngineURL.absoluteString,
            macLocalPairing: localPairing
        )
        return try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> SetupInvitationDirectClaim {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let url = URL(string: envelope.macEngineURL),
              let tokenBytes = PairingCrypto.base64URLDecode(envelope.token) else {
            throw SetupInvitationDirectError.invalidEnvelope
        }
        let token = try SetupInvitationToken(bytes: tokenBytes)
        let localPairing: SetupInvitationMacLocalPairing?
        if let pairing = envelope.macLocalPairing {
            guard let macID = UUID(uuidString: pairing.macID),
                  let secret = PairingCrypto.base64URLDecode(pairing.secret),
                  pairing.presencePort > 0,
                  pairing.attachPort > 0,
                  !pairing.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SetupInvitationDirectError.invalidEnvelope
            }
            localPairing = SetupInvitationMacLocalPairing(
                macID: macID,
                macName: pairing.macName,
                host: pairing.host,
                presencePort: pairing.presencePort,
                attachPort: pairing.attachPort,
                secret: secret
            )
        } else {
            localPairing = nil
        }
        return SetupInvitationDirectClaim(
            token: token,
            macEngineURL: url,
            macLocalPairing: localPairing
        )
    }

    public static func decode(
        _ data: Data,
        expectedToken: SetupInvitationToken
    ) throws -> SetupInvitationDirectClaim {
        let claim = try decode(data)
        guard claim.token == expectedToken else {
            throw SetupInvitationDirectError.unauthorizedClaim
        }
        return claim
    }

    private struct Envelope: Codable {
        let token: String
        let macEngineURL: String
        let macLocalPairing: MacLocalPairingEnvelope?

        enum CodingKeys: String, CodingKey {
            case token
            case macEngineURL = "mac_engine_url"
            case macLocalPairing = "mac_local_pairing"
        }
    }

    private struct MacLocalPairingEnvelope: Codable {
        let macID: String
        let macName: String
        let host: String
        let presencePort: Int
        let attachPort: Int
        let secret: String

        enum CodingKeys: String, CodingKey {
            case macID = "mac_id"
            case macName = "mac_name"
            case host
            case presencePort = "presence_port"
            case attachPort = "attach_port"
            case secret
        }
    }
}

public enum SetupInvitationDirectError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unauthorizedClaim
}

private struct SetupInvitationDirectEnvelope: Codable {
    let version: UInt8
    let token: String
    let ownerDisplayName: String?
    let expiresAt: UInt64
    let iphoneApnsToken: String?
    let iphoneDeviceID: String?
    let iphoneDeviceName: String?
    let iphoneDeviceModel: String?

    enum CodingKeys: String, CodingKey {
        case version
        case token
        case ownerDisplayName = "owner_display_name"
        case expiresAt = "expires_at"
        case iphoneApnsToken = "iphone_apns_token"
        case iphoneDeviceID = "iphone_device_id"
        case iphoneDeviceName = "iphone_device_name"
        case iphoneDeviceModel = "iphone_device_model"
    }
}

private struct DirectHTTPRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) -> DirectHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = contentLength == 0 ? Data() : data[bodyStart..<(bodyStart + contentLength)]
        let rawPath = requestParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestParts[1]
        return DirectHTTPRequest(
            method: requestParts[0].uppercased(),
            path: rawPath,
            body: Data(body)
        )
    }
}

// MARK: - NWParameters extension

extension NWParameters {
    /// Parameters that restrict publishing to Tailscale interfaces only (FR-040).
    /// Tailscale uses userspace tun, exposed as `.other` interface type on Apple platforms.
    public static func tailscaleOnly() -> NWParameters {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .other
        return params
    }
}

// MARK: - Data extension

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
