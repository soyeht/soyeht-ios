import Foundation
import Network

/// Mac-side Bonjour browser for `_soyeht-setup._tcp.` (Caso B).
///
/// Discovers the iPhone's setup invitation service over Tailscale, decodes the
/// CBOR TXT record, and exposes the `SetupInvitationPayload` for the Mac to call
/// `POST /bootstrap/claim-setup-invitation`.
///
/// Only browses on `.other` interface type (Tailscale). Plain LAN browsing is
/// skipped unless `allowPlainLAN` is set at init time.
public final class SetupInvitationBrowser: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case browsing
        case discovered(SetupInvitationPayload)
        case failed(String)
        case stopped
    }

    public enum BrowseError: Error, Sendable {
        case invalidTXTRecord
        case decodingFailed
        case tokenExpired
    }

    private let parameters: NWParameters
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.soyeht.setup-invitation.browser")

    private var _state: State = .idle
    public private(set) var state: State {
        get { _state }
        set { _state = newValue; onStateChange?(newValue) }
    }

    /// Called on the browser's internal queue when state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(parameters: NWParameters = .tailscaleOnly()) {
        self.parameters = parameters
    }

    /// Starts browsing for `_soyeht-setup._tcp.` services.
    public func start() {
        queue.async { self._start() }
    }

    /// Stops browsing.
    public func stop() {
        queue.async { self._stop() }
    }

    // MARK: - Private

    private func _start() {
        guard _state == .idle || _state == .stopped else { return }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_soyeht-setup._tcp.", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self.queue.async {
                switch newState {
                case .ready:
                    if case .browsing = self._state {} else {
                        self.state = .browsing
                    }
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .stopped
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.queue.async {
                for result in results {
                    if case .service(let name, let type, let domain, let iface) = result.endpoint,
                       type == "_soyeht-setup._tcp." {
                        _ = (name, domain, iface)
                        if let payload = self.extractPayload(from: result) {
                            self.state = .discovered(payload)
                            return
                        }
                    }
                }
            }
        }

        self.browser = browser
        state = .browsing
        browser.start(queue: queue)
    }

    private func _stop() {
        browser?.cancel()
        browser = nil
        state = .stopped
    }

    private func extractPayload(from result: NWBrowser.Result) -> SetupInvitationPayload? {
        guard case .service = result.endpoint else { return nil }

        // Extract TXT record from metadata
        if case .bonjour(let record) = result.metadata {
            guard let mValue = record["m"],
                  let cbor = Data(base64URLEncoded: mValue) else {
                return nil
            }
            return try? decodeCBOR(cbor)
        }
        return nil
    }

    private func decodeCBOR(_ data: Data) throws -> SetupInvitationPayload {
        guard case .map(let map) = try HouseholdCBOR.decode(data) else {
            throw BrowseError.decodingFailed
        }

        guard case .unsigned(1) = map["v"],
              case .bytes(let tokenBytes) = map["token"],
              case .unsigned(let expiresAt) = map["expires_at"] else {
            throw BrowseError.decodingFailed
        }

        let token = try SetupInvitationToken(bytes: tokenBytes)

        var ownerDisplayName: String?
        if let v = map["owner_display_name"], case .text(let name) = v {
            ownerDisplayName = name
        }

        var iphoneApnsToken: Data?
        if let v = map["iphone_apns_token"], case .bytes(let bytes) = v {
            iphoneApnsToken = bytes
        }

        let now = UInt64(Date().timeIntervalSince1970)
        guard expiresAt > now else {
            throw BrowseError.tokenExpired
        }

        return SetupInvitationPayload(
            token: token,
            ownerDisplayName: ownerDisplayName,
            expiresAt: expiresAt,
            iphoneApnsToken: iphoneApnsToken
        )
    }
}

// MARK: - Data base64URL helpers

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
