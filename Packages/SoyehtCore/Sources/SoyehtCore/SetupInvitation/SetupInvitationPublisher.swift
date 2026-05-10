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
    public enum State: Equatable, Sendable {
        case idle
        case publishing
        case failed(String)
        case stopped
    }

    private let invitation: SetupInvitationPayload
    private let parameters: NWParameters
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.soyeht.setup-invitation.publisher")

    private var _state: State = .idle
    public private(set) var state: State {
        get { _state }
        set { _state = newValue; onStateChange?(newValue) }
    }

    /// Called on the publisher's internal queue when `state` changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(invitation: SetupInvitationPayload, parameters: NWParameters = .tailscaleOnly()) {
        self.invitation = invitation
        self.parameters = parameters
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
            let cbor = try invitation.encodedTXTValue()
            txtRecord = NWTXTRecord(["m": cbor])
        } catch {
            state = .failed("TXT encode failed: \(error)")
            return
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
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

        self.listener = listener
        listener.start(queue: queue)
    }

    private func _stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
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

    public init(
        token: SetupInvitationToken,
        ownerDisplayName: String?,
        expiresAt: UInt64,
        iphoneApnsToken: Data?
    ) {
        self.token = token
        self.ownerDisplayName = ownerDisplayName
        self.expiresAt = expiresAt
        self.iphoneApnsToken = iphoneApnsToken
    }

    /// Encodes the payload as CBOR then base64url for the TXT `m` key.
    func encodedTXTValue() throws -> String {
        let cbor = encodeCBOR()
        return cbor.base64URLEncodedString()
    }

    func encodeCBOR() -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(1),
            "token": .bytes(token.bytes),
            "expires_at": .unsigned(expiresAt),
        ]
        map["owner_display_name"] = ownerDisplayName.map { .text($0) } ?? .null
        map["iphone_apns_token"] = iphoneApnsToken.map { .bytes($0) } ?? .null
        return HouseholdCBOR.encode(.map(map))
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
