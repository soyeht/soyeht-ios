import Foundation
import SoyehtCore
import os

private let pairingAdvertisementLogger = Logger(
    subsystem: "com.soyeht.mac",
    category: "pairing-advertisement"
)

/// The one pairing link this Mac is offering, and the six words that go with it.
///
/// Three places used to mint their own: the house card during setup, the Add
/// iPhone sheet in Settings, and the background listener that watches for a
/// phone all day. The background one re-minted every loop — a new nonce every
/// half second — so the words on screen and the words the phone was told to
/// expect came from whichever listener claimed the invitation first. When they
/// disagreed, the phone said it could not verify the Mac's security code, and
/// nothing on either screen explained why.
///
/// It also has a clock. The engine's link closes after a few minutes; nothing
/// noticed. The words simply vanished from the Mac's own screen on the next
/// re-render while the QR beside them kept showing a dead link. This object
/// re-fetches before that happens, and everything that displays the offer
/// follows because they all read this one object.
@MainActor
final class MacPairingAdvertisement: ObservableObject {
    static let shared = MacPairingAdvertisement()

    struct Offer: Equatable {
        let uri: String
        let houseName: String
        let hostLabel: String
        let words: [String]
        /// Present only for an engine-minted link; a Mac-minted one has no
        /// window to outlive.
        let expiresAt: Date?
        let isEngineMinted: Bool
    }

    @Published private(set) var offer: Offer?

    private var refreshTask: Task<Void, Never>?
    private var starts = 0
    /// The Mac-minted nonce is held for the life of the app, so the words stay
    /// put while the endpoint underneath them is re-resolved. Re-minting it on
    /// a refresh would change the code someone is in the middle of reading.
    private var macMintedNonce: Data?

    private let baseURL: () -> URL
    private let now: () -> Date

    init(
        baseURL: @escaping () -> URL = { TheyOSEnvironment.bootstrapBaseURL },
        now: @escaping () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.now = now
    }

    /// Reference-counted: the house card, the Settings sheet and the
    /// background listener can all be interested at once, and the last one to
    /// leave turns the loop off.
    func start() {
        starts += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waited = await self.refreshOnce()
                try? await Task.sleep(for: .seconds(waited))
            }
        }
    }

    func stop() {
        starts = max(0, starts - 1)
        guard starts == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Drops the current offer so the next refresh mints a new one. Used when
    /// a pairing completes: the words that were on screen are spent.
    func invalidate() {
        offer = nil
        macMintedNonce = nil
    }

    /// For callers outside SwiftUI that need the current offer and can wait a
    /// beat for the first fetch.
    func currentOffer() async -> Offer? {
        if let offer { return offer }
        _ = await refreshOnce()
        return offer
    }

    /// Returns how many seconds to wait before refreshing again.
    @discardableResult
    private func refreshOnce() async -> Double {
        let base = baseURL()
        guard let status = try? await BootstrapStatusClient(baseURL: base).fetch() else {
            return 2
        }

        switch status.state {
        case .namedAwaitingPair:
            return await refreshEngineMintedOffer(base: base)
        case .ready:
            return refreshMacMintedOffer(base: base, hostLabel: status.hostLabel)
        case .uninitialized, .readyForNaming, .recovering:
            // No house to offer yet. Anything still holding an old offer would
            // be showing a code for a household that no longer exists.
            offer = nil
            return 2
        }
    }

    private func refreshEngineMintedOffer(base: URL) async -> Double {
        guard let response = try? await BootstrapPairDeviceURIClient(baseURL: base).fetch() else {
            return 2
        }
        let expiresAt = response.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        guard let words = try? PairingCodePresentation.words(
            pairingURI: response.pairDeviceURI,
            now: now()
        ) else {
            // A link we cannot read is a link we must not show. Ask again
            // shortly; the engine re-opens the window on the next fetch.
            pairingAdvertisementLogger.error("pairing_offer.unreadable_engine_link")
            offer = nil
            return 2
        }

        offer = Offer(
            uri: response.pairDeviceURI,
            houseName: response.houseName,
            hostLabel: response.hostLabel,
            words: words,
            expiresAt: expiresAt,
            isEngineMinted: true
        )
        return Self.secondsUntilRefresh(expiresAt: expiresAt, now: now())
    }

    private func refreshMacMintedOffer(base: URL, hostLabel: String) -> Double {
        // The endpoint is re-resolved every time: a Mac that moved between
        // Wi-Fi and the tailnet would otherwise hand out an address it no
        // longer answers on. The nonce is not, so the words hold still.
        let nonce = macMintedNonce ?? PairingCrypto.randomBytes(
            count: HouseholdDevicePairingLink.pairingNonceLength
        )
        macMintedNonce = nonce

        guard let identity = MacPairingIdentityCache.shared.identity else {
            Task { await MacPairingIdentityCache.shared.load(baseURL: base) }
            return 2
        }

        let link = HouseholdDevicePairingLink(
            endpoint: MacEngineAdvertisedURL.current(localEngineBaseURL: base),
            householdId: identity.householdId,
            householdPublicKey: identity.householdPublicKey,
            householdName: identity.name,
            pairingNonce: nonce
        )
        guard let uri = try? link.url().absoluteString,
              let words = try? PairingCodePresentation.words(pairingURI: uri, now: now()) else {
            pairingAdvertisementLogger.error("pairing_offer.unreadable_mac_link")
            offer = nil
            return 2
        }

        offer = Offer(
            uri: uri,
            houseName: identity.name,
            hostLabel: hostLabel,
            words: words,
            expiresAt: nil,
            isEngineMinted: false
        )
        return 30
    }

    /// Refresh ten seconds before the window closes, and at least every half
    /// minute so a moved Mac does not advertise a stale address for long.
    ///
    /// Pure, and off the main actor, so the schedule can be tested without a
    /// running engine.
    nonisolated static func secondsUntilRefresh(expiresAt: Date?, now: Date) -> Double {
        guard let expiresAt else { return 30 }
        let lead = expiresAt.timeIntervalSince(now) - 10
        return min(30, max(1, lead))
    }
}

/// The household identity behind the Mac-minted link. Cached because the offer
/// is re-resolved on a timer and the identity does not change while the app
/// runs.
@MainActor
final class MacPairingIdentityCache {
    static let shared = MacPairingIdentityCache()

    struct Identity: Equatable {
        let householdId: String
        let householdPublicKey: Data
        let name: String
    }

    private(set) var identity: Identity?
    private var inFlight = false

    func load(baseURL: URL) async {
        guard identity == nil, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let url = baseURL.appendingPathComponent("api/v1/household/identity")
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let publicKey = Data(base64Encoded: envelope.householdPublicKeyBase64),
              publicKey.count == HouseholdIdentifiers.compressedP256PublicKeyLength else {
            return
        }
        identity = Identity(
            householdId: envelope.householdId,
            householdPublicKey: publicKey,
            name: envelope.name
        )
    }

    func forget() { identity = nil }

    private struct Envelope: Decodable {
        let householdId: String
        let householdPublicKeyBase64: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case householdId = "hh_id"
            case householdPublicKeyBase64 = "hh_pub_b64"
            case name
        }
    }
}
