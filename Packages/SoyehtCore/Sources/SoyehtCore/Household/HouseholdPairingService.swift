import Foundation
import os

/// Why `Logger` and not `NSLog`: on a device, `NSLog` from this package never
/// reaches `idevicesyslog`, so the one message that says WHICH guard refused a
/// freshly minted cert was invisible exactly where it matters — a phone that
/// paired successfully server-side and then threw the session away. Every
/// field below is a shape or an identifier the pairing link already carries in
/// the clear; no key, no cert body, no nonce.
private let householdPairingLogger = Logger(subsystem: "com.soyeht.core", category: "household-pairing")

/// Severity for a pair-flow diagnostic. Two levels only: `info` for the
/// measurements a successful run also emits (they are what a later failure is
/// compared against), `error` for the line that names a refusal.
enum HouseholdPairingLogLevel: String, Sendable {
    case info
    case error
}

typealias HouseholdPairingLogSink = @Sendable (HouseholdPairingLogLevel, String) -> Void

/// Why the pair flow logs through an injectable sink instead of touching
/// `householdPairingLogger` directly: these lines exist so a captured log can
/// say WHICH guard refused a freshly minted cert, and a log no test can read is
/// a log that silently stops being emitted the next time this function is
/// edited. Production keeps going to `os.Logger` — `idevicesyslog` is where the
/// line is actually read off a device.
let householdPairingDefaultLogSink: HouseholdPairingLogSink = { level, message in
    switch level {
    case .info:
        householdPairingLogger.info("\(message, privacy: .public)")
    case .error:
        householdPairingLogger.error("\(message, privacy: .public)")
    }
}

public struct PairDeviceConfirmResponse: Decodable, Equatable, Sendable {
    public let v: Int
    public let householdId: String
    public let personId: String
    public let personCertCBOR: String
    public let capabilities: [String]
    public let deviceCert: String?

    enum CodingKeys: String, CodingKey {
        case v
        case householdId = "hh_id"
        case personId = "p_id"
        case personCertCBOR = "person_cert_cbor"
        case capabilities
        case deviceCert = "device_cert"
    }

    public init(
        v: Int,
        householdId: String,
        personId: String,
        personCertCBOR: String,
        capabilities: [String],
        deviceCert: String? = nil
    ) {
        self.v = v
        self.householdId = householdId
        self.personId = personId
        self.personCertCBOR = personCertCBOR
        self.capabilities = capabilities
        self.deviceCert = deviceCert
    }
}

public protocol HouseholdPairingHTTPClient: Sendable {
    func confirmPairing(
        endpoint: URL,
        body: PairDeviceConfirmRequest
    ) async throws -> PairDeviceConfirmResponse
}

public struct URLSessionHouseholdPairingHTTPClient: HouseholdPairingHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// One pairing ceremony's worth of patience. Long enough for a tailnet
    /// hop on a slow phone, short enough that a wrong address says so while
    /// the person is still looking at the screen.
    static let confirmTimeoutSeconds: TimeInterval = 15

    public func confirmPairing(
        endpoint: URL,
        body: PairDeviceConfirmRequest
    ) async throws -> PairDeviceConfirmResponse {
        let url = endpoint.appending(path: "/api/v1/household/pair-device/confirm")
        householdPairingLogger.info("pair.confirm.post host=\(url.host() ?? "<none>", privacy: .public) port=\(url.port ?? -1, privacy: .public)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        // Explicit, because the plain-HTTP path no longer treats a connection
        // stuck in `.waiting` as fatal: without a deadline of its own an
        // unroutable engine would hold the pairing screen for URLRequest's
        // inherited 60 s, which is the shape of "it just sat there" rather
        // than a failure anyone can act on.
        request.timeoutInterval = Self.confirmTimeoutSeconds
        let (data, response) = try await Self.perform(request, session: session)
        // Measure the answer before anything can reject it. Without these two
        // numbers a run that failed after a *successful* server-side confirm
        // (engine says ready, device_count 1) cannot be told apart from one
        // where the body never fully arrived: both surface to the user as the
        // same catch-all sentence. `status=-1` means the response was not even
        // an HTTP response.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        householdPairingLogger.info("pair.confirm.response status=\(statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        guard (200...299).contains(statusCode) else {
            householdPairingLogger.error("pair.pairingRejected status=\(statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
            throw HouseholdPairingError.pairingRejected
        }
        do {
            return try JSONDecoder().decode(PairDeviceConfirmResponse.self, from: data)
        } catch {
            // A 2xx we could not read is not a transport drop; say so here
            // because the caller can only roll this up into a generic
            // `networkUnavailable`.
            householdPairingLogger.error(
                "pair.confirm.decodeFailed bytes=\(data.count, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        guard request.url?.scheme?.lowercased() == "http" else {
            return try await session.data(for: request)
        }
        return try await PlainHTTPTransaction(request: request).perform()
    }
}

public struct HouseholdPairingService {
    private static let maxPersonCertCBORBase64URLBytes = 90_000

    private let browser: any HouseholdBonjourBrowsing
    private let keyProvider: any OwnerIdentityKeyCreating
    private let httpClient: any HouseholdPairingHTTPClient
    private let sessionStore: HouseholdSessionStore
    private let rosterStorage: any HouseholdSecureStoring
    private let rosterAccount: String
    private let now: @Sendable () -> Date
    /// Seconds since the epoch as text. `Int(_:)` traps on a value a
    /// certificate is free to carry, and a diagnostic must not crash the
    /// pairing it exists to explain.
    static func epochString(_ date: Date) -> String {
        String(format: "%.0f", date.timeIntervalSince1970)
    }

    /// How far past `from` this phone believes it is. Negative means the
    /// certificate is still future-dated here — the only shape in which the
    /// window can refuse a cert the Mac just minted.
    static func millisecondsString(from: Date, to: Date) -> String {
        String(format: "%.0f", to.timeIntervalSince(from) * 1000)
    }

    private let log: HouseholdPairingLogSink

    public init(
        browser: any HouseholdBonjourBrowsing = HouseholdBonjourBrowser(),
        keyProvider: any OwnerIdentityKeyCreating = SecureEnclaveOwnerIdentityKeyProvider(),
        httpClient: any HouseholdPairingHTTPClient = URLSessionHouseholdPairingHTTPClient(),
        sessionStore: HouseholdSessionStore = HouseholdSessionStore(),
        rosterStorage: any HouseholdSecureStoring = RosterProjectionStore.defaultStorage(),
        rosterAccount: String = RosterProjectionStore.defaultAccount,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            browser: browser,
            keyProvider: keyProvider,
            httpClient: httpClient,
            sessionStore: sessionStore,
            rosterStorage: rosterStorage,
            rosterAccount: rosterAccount,
            now: now,
            log: householdPairingDefaultLogSink
        )
    }

    /// Same flow with the diagnostic sink swapped out, so a test can assert a
    /// refusal named itself instead of only asserting the rolled-up
    /// `HouseholdPairingError`.
    init(
        browser: any HouseholdBonjourBrowsing,
        keyProvider: any OwnerIdentityKeyCreating,
        httpClient: any HouseholdPairingHTTPClient,
        sessionStore: HouseholdSessionStore,
        rosterStorage: any HouseholdSecureStoring,
        rosterAccount: String,
        now: @escaping @Sendable () -> Date,
        log: @escaping HouseholdPairingLogSink
    ) {
        self.log = log
        self.browser = browser
        self.keyProvider = keyProvider
        self.httpClient = httpClient
        self.sessionStore = sessionStore
        self.rosterStorage = rosterStorage
        self.rosterAccount = rosterAccount
        self.now = now
    }

    /// - Parameter reachedEndpoint: an address this phone has ALREADY talked to
    ///   the Mac on, when the caller has one. It wins over the host inside the
    ///   link.
    ///
    ///   WHY IT WINS. The engine mints the link with `best_qr_host()`, which is
    ///   the tailnet address whenever the Mac has one — and never a LAN
    ///   address, by design. MEASURED on the owner's Dev pair 2026-09-05 with
    ///   the phone's Tailscale off: the phone found the Mac over Wi-Fi
    ///   (`mac_browser.endpoint endpoint=http://192.168.1.20:8101`), showed the
    ///   card, and then sent the confirm to the address in the link:
    ///
    ///       pair.confirm.post host=<tailnet> port=8101
    ///       pair.networkUnavailable stage=confirm ... stage=timeout
    ///
    ///   It had a working address in hand and used one it could not reach. The
    ///   link's host is a FALLBACK for a phone that has nothing better — a QR
    ///   scanned off the screen with no discovery behind it. A caller that
    ///   already completed a round trip knows more than the paper does.
    public func pair(
        url: URL,
        displayName: String,
        reachedEndpoint: URL? = nil
    ) async throws -> ActiveHouseholdState {
        let qr: PairDeviceQR
        do {
            qr = try PairDeviceQR(url: url, now: now())
        } catch PairDeviceQRError.expired {
            throw HouseholdPairingError.expiredQR
        } catch {
            throw HouseholdPairingError.invalidQR
        }

        let candidate: HouseholdDiscoveryCandidate
        if let reachedEndpoint {
            log(.info, "pair.endpoint source=reached host=\(reachedEndpoint.host() ?? "<none>") port=\(reachedEndpoint.port ?? -1)")
            candidate = HouseholdDiscoveryCandidate(
                endpoint: reachedEndpoint,
                householdId: qr.householdId,
                householdName: qr.householdName,
                machineId: nil,
                pairingState: "device",
                shortNonce: ""
            )
        } else if let endpoint = Self.directEndpoint(for: qr) {
            // Founder embedded a Tailnet host fallback in the QR (engine's
            // bonjour publisher is known broken cross-platform — Linux
            // mdns-sd does not emit announce records visible to macOS/iOS
            // NWBrowser). Skip Bonjour browse entirely. The household
            // identity is still verified by `PairingProof.confirmRequest`
            // through `qr.householdPublicKey` so this fallback path
            // inherits the same trust model as Bonjour discovery.
            candidate = HouseholdDiscoveryCandidate(
                endpoint: endpoint,
                householdId: qr.householdId,
                householdName: qr.householdName,
                machineId: nil,
                pairingState: "device",
                shortNonce: ""
            )
        } else {
            do {
                candidate = try await browser.firstMatchingCandidate(
                    for: qr,
                    timeout: OnboardingConfig.default.householdDiscoveryTimeout
                )
            } catch let error as HouseholdPairingError {
                throw error
            } catch {
                throw HouseholdPairingError.noMatchingHousehold
            }
        }

        let ownerIdentity: any OwnerIdentitySigning
        do {
            ownerIdentity = try keyProvider.createOwnerIdentity(displayName: displayName)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdPairingError.biometryCanceled
        } catch let inner {
            // Forward the underlying OwnerIdentityKeyError so a generic
            // `identityKeyUnavailable` surfaced to the user still leaves a
            // diagnosis trail on the device. The error is otherwise opaque to
            // callers that catch the rolled-up `HouseholdPairingError`.
            log(.error, "pair.identityKeyUnavailable stage=keyCreate error=\(String(describing: inner))")
            throw HouseholdPairingError.identityKeyUnavailable
        }

        let request: PairDeviceConfirmRequest
        do {
            request = try PairingProof.confirmRequest(qr: qr, ownerIdentity: ownerIdentity, displayName: displayName)
        } catch OwnerIdentityKeyError.biometryCanceled {
            throw HouseholdPairingError.biometryCanceled
        } catch let inner {
            // The PoP signing step had no line at all, so the same
            // `identityKeyUnavailable` the user sees could come from here or
            // from key creation above with nothing on the device to separate
            // them. `stage=` is the separator.
            log(.error, "pair.identityKeyUnavailable stage=proof error=\(String(describing: inner))")
            throw HouseholdPairingError.identityKeyUnavailable
        }

        let response: PairDeviceConfirmResponse
        do {
            response = try await httpClient.confirmPairing(endpoint: candidate.endpoint, body: request)
        } catch let error as HouseholdPairingError {
            throw error
        } catch {
            log(.error, "pair.networkUnavailable stage=confirm type=\(type(of: error)) error=\(String(describing: error))")
            throw HouseholdPairingError.networkUnavailable
        }

        guard response.v == 1 else {
            log(.error, "pair.certInvalid guard=v expected=1 got=\(response.v)")
            throw HouseholdPairingError.certInvalid
        }
        guard response.deviceCert == nil else {
            log(.error, "pair.certInvalid guard=deviceCert_present")
            throw HouseholdPairingError.certInvalid
        }
        guard response.householdId == qr.householdId, response.personId == ownerIdentity.personId else {
            log(
                .error,
                "pair.certInvalid guard=ids hh_match=\(response.householdId == qr.householdId) pid_match=\(response.personId == ownerIdentity.personId)"
            )
            throw HouseholdPairingError.certInvalid
        }
        guard response.personCertCBOR.utf8.count <= Self.maxPersonCertCBORBase64URLBytes else {
            log(
                .error,
                "pair.certInvalid guard=cborSize bytes=\(response.personCertCBOR.utf8.count) cap=\(Self.maxPersonCertCBORBase64URLBytes)"
            )
            throw HouseholdPairingError.certInvalid
        }

        let certData: Data
        do {
            certData = try Data(soyehtBase64URL: response.personCertCBOR)
            let cert = try PersonCert(cbor: certData)
            guard Set(response.capabilities) == Set(cert.caveats.map(\.operation)) else {
                log(
                    .error,
                    "pair.certInvalid guard=capabilities response=\(Set(response.capabilities).sorted().joined(separator: ",")) certOps=\(Set(cert.caveats.map(\.operation)).sorted().joined(separator: ","))"
                )
                throw HouseholdPairingError.certInvalid
            }
            // `notBefore <= now` is the ONLY time-dependent guard in
            // `cert.validate`, and the engine signs `not_before = issued_at`
            // at whole-second resolution — a phone whose clock trails the Mac
            // by a few hundred ms refuses a cert the Mac just minted, which is
            // the shape of the ~3-in-7 from-scratch failures. Measure the three
            // inputs BEFORE the guard runs so one captured line decides it:
            // `skewMs` is how far past `not_before` this phone believes it is,
            // so a NEGATIVE value means the cert is still future-dated here.
            let validationNow = now()
            // Formatted, never converted with `Int(_:)`: a `not_before` far
            // enough from the epoch traps, and a diagnostic line has no
            // business crashing the pairing it exists to explain — a
            // malformed or hostile certificate must still come out the other
            // side as a refusal.
            //
            // `notAfter` is logged beside it because `cert.validate` folds
            // BOTH ends of the window into the same `invalidValidityWindow`;
            // without it a captured line cannot say which end refused.
            log(
                .info,
                "pair.cert.validity notBefore=\(Self.epochString(cert.notBefore)) notAfter=\(cert.notAfter.map(Self.epochString) ?? "none") issuedAt=\(cert.issuedAt.map(Self.epochString) ?? "none") now=\(Self.epochString(validationNow)) skewMs=\(Self.millisecondsString(from: cert.notBefore, to: validationNow))"
            )
            try cert.validate(
                householdId: qr.householdId,
                householdPublicKey: qr.householdPublicKey,
                ownerPersonId: ownerIdentity.personId,
                ownerPersonPublicKey: ownerIdentity.publicKey,
                now: validationNow
            )
            let state = ActiveHouseholdState(
                householdId: qr.householdId,
                householdName: candidate.householdName,
                householdPublicKey: qr.householdPublicKey,
                endpoint: candidate.endpoint,
                ownerPersonId: ownerIdentity.personId,
                ownerPublicKey: ownerIdentity.publicKey,
                ownerKeyReference: ownerIdentity.keyReference,
                personCert: cert,
                pairedAt: now(),
                lastSeenAt: now()
            )
            // Root the roster store on the QR's machine-cert fingerprint before
            // the session exists. The anchor comes from `qr`, never from
            // `candidate`: the candidate is unauthenticated discovery data,
            // while the QR fields are the same ones `cert.validate` was just
            // anchored on. Seeding first means a household can never become
            // active with an unrooted roster store — `refresh` would find
            // `.absent` and never fetch. The reverse ordering is safe: a seeded
            // anchor without a session is inert (nothing reads the roster store
            // until a household is active) and a retry with the same QR is
            // idempotent, since `seedPendingAnchor` re-reads the persisted
            // anchor and returns early when it matches.
            let rosterStore = RosterProjectionStore(
                expectedHouseholdId: qr.householdId,
                householdPublicKey: qr.householdPublicKey,
                storage: rosterStorage,
                account: rosterAccount
            )
            try await rosterStore.seedPendingAnchor(qrAnchorFingerprint: qr.machineCertFingerprint)
            try sessionStore.save(state)
            return state
        } catch let error as HouseholdSessionError {
            // Every case here is a fault in writing OUR OWN session record —
            // `encodingFailed`/`decodingFailed` included. Those two used to
            // fall through to the catch-all and tell the user their
            // certificate was bad, which sent them to re-scan a QR for a
            // failure no new QR can fix.
            log(.error, "pair.storageFailed stage=session case=\(error)")
            throw HouseholdPairingError.storageFailed
        } catch let error as RosterProjectionStoreError {
            // Must precede the catch-all: a refused roster write is a storage
            // fault, not evidence that the person cert is bad. Letting it fall
            // through to `certInvalid` would tell the user to re-pair with a
            // different QR for a failure no new QR can fix.
            log(.error, "pair.storageFailed stage=rosterAnchor error=\(String(describing: error))")
            throw HouseholdPairingError.storageFailed
        } catch let error as HouseholdPairingError {
            throw error
        } catch let error as PersonCertError {
            // The cert really is the thing being refused here, so the rolled-up
            // error stays `certInvalid` — but say WHICH of the fifteen
            // rejections fired, whether it came from the decode or from
            // `validate`. `invalidValidityWindow` is the clock-skew one.
            log(.error, "pair.certInvalid guard=personCert case=\(error)")
            throw HouseholdPairingError.certInvalid
        } catch let error as HouseholdCBORError {
            log(.error, "pair.certInvalid guard=cborDecode case=\(error)")
            throw HouseholdPairingError.certInvalid
        } catch {
            // Anything still unnamed: print the concrete type, because the
            // description alone has repeatedly been too generic to act on.
            log(.error, "pair.certInvalid guard=catchAll type=\(type(of: error)) error=\(String(describing: error))")
            throw HouseholdPairingError.certInvalid
        }
    }

    /// Constructs an HTTP endpoint URL from a QR's `host` fallback field if
    /// present (`<addr>:<port>` syntax). Returns nil when the QR did not
    /// carry an explicit host — callers must then fall back to Bonjour
    /// discovery. The fallback is plain HTTP because the engine only
    /// listens on cleartext within Tailscale's encrypted overlay and on
    /// loopback. ATS allows arbitrary cleartext loads for the same reason
    /// (see Soyeht/Info.plist).
    ///
    /// The QR is unauthenticated paper/URI input. Foundation's
    /// `URL(string:)` happily parses `host=evil.com@victim:8091/path?x=`
    /// into a userinfo+host+path form that redirects the confirm POST off
    /// the candidate. Even though the cert exchange is still anchored on
    /// `qr.householdPublicKey`, a rogue endpoint receives the freshly
    /// minted owner pubkey + PoP and can DoS or SSRF arbitrary Tailnet
    /// hosts. Validate the parsed components strictly: `host` is a bare
    /// IPv4/IPv6/hostname, optional numeric `port`, no userinfo, no path,
    /// no query, no fragment.
    static func directEndpoint(for qr: PairDeviceQR) -> URL? {
        guard let raw = qr.hostFallback, !raw.isEmpty else { return nil }
        return EndpointPolicy.localPlainHTTPURL(authority: raw)
    }
}
