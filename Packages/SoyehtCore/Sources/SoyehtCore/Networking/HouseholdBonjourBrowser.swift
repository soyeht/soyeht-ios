import Foundation
import Network
import os

private let bonjourBrowserDiscoveryLogger = Logger(subsystem: "com.soyeht.mobile", category: "household-bonjour-discovery")

public struct HouseholdDiscoveryCandidate: Equatable, Sendable {
    public let endpoint: URL
    public let householdId: String
    public let householdName: String
    public let machineId: String?
    public let pairingState: String
    public let shortNonce: String

    public init(
        endpoint: URL,
        householdId: String,
        householdName: String,
        machineId: String?,
        pairingState: String,
        shortNonce: String
    ) {
        self.endpoint = endpoint
        self.householdId = householdId
        self.householdName = householdName
        self.machineId = machineId
        self.pairingState = pairingState
        self.shortNonce = shortNonce
    }

    /// Match a `_soyeht-household._tcp` candidate against a scanned
    /// `pair-device` QR.
    ///
    /// The expected TXT value for `pairing` on a Phase 2 owner-pairing
    /// publisher is `"device"` — see theyos `docs/household-protocol.md`
    /// §13 (canonical source). A previous revision used `"open"`,
    /// which was a stale copy from a pre-FR-018 design that was never
    /// reconciled with the published protocol; theyos PR #42 corrected
    /// the publisher doc-comment, and this filter follows.
    ///
    /// `"machine"` is reserved for Phase 3 (single-machine → 2-machine
    /// join) and intentionally NOT matched here — that flow has its own
    /// browser/QR pair and would otherwise be admitted into the owner
    /// pairing path silently.
    public func matches(qr: PairDeviceQR) -> Bool {
        householdId == qr.householdId
            && pairingState == "device"
            && qr.shortNonce == shortNonce
    }
}

public protocol HouseholdBonjourBrowsing: Sendable {
    func firstMatchingCandidate(for qr: PairDeviceQR, timeout: TimeInterval) async throws -> HouseholdDiscoveryCandidate
}

public struct HouseholdBonjourBrowser: HouseholdBonjourBrowsing {
    public init() {}

    public func firstMatchingCandidate(
        for qr: PairDeviceQR,
        timeout: TimeInterval = 10
    ) async throws -> HouseholdDiscoveryCandidate {
        try await withThrowingTaskGroup(of: HouseholdDiscoveryCandidate.self) { group in
            group.addTask {
                try await Self.browse(for: qr)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw HouseholdPairingError.noMatchingHousehold
            }
            guard let result = try await group.next() else {
                throw HouseholdPairingError.noMatchingHousehold
            }
            group.cancelAll()
            return result
        }
    }

    private static func browse(for qr: PairDeviceQR) async throws -> HouseholdDiscoveryCandidate {
        final class BrowseSession: @unchecked Sendable {
            let browser = NWBrowser(
                for: .bonjour(type: "_soyeht-household._tcp", domain: nil),
                using: .tcp
            )
            let lock = NSLock()
            var continuation: CheckedContinuation<HouseholdDiscoveryCandidate, Error>?
            var resumed = false

            func start(for qr: PairDeviceQR) async throws -> HouseholdDiscoveryCandidate {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if resumed {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    lock.unlock()

                    browser.browseResultsChangedHandler = { results, _ in
                        // Production-grade discovery telemetry — emits
                        // a structured trail to `os_log` (subsystem
                        // `com.soyeht.mobile`, category
                        // `household-bonjour-discovery`) so support
                        // can triage user reports of pairing
                        // failures via Console.app + Sysdiagnose
                        // without needing to reproduce locally. Sender
                        // metadata (TXT dict, candidate URL,
                        // match-state) is `privacy: .public` only for
                        // protocol-level fields that are already
                        // discoverable on the LAN; nothing
                        // user-personal is logged.
                        bonjourBrowserDiscoveryLogger.info("browseResultsChanged count=\(results.count, privacy: .public) qrHouseholdId=\(qr.householdId, privacy: .public) qrShortNonce=\(qr.shortNonce, privacy: .public)")
                        for result in results {
                            let endpointDescription = String(describing: result.endpoint)
                            let txt: [String: String]
                            if case .bonjour(let record) = result.metadata {
                                txt = record.dictionary
                            } else {
                                txt = [:]
                            }
                            // Per-result TXT dump uses `.debug` so it
                            // does not balloon Sysdiagnose volume on
                            // busy LANs with multiple publishers. The
                            // `.info` lines above (browse delta count)
                            // and below (candidate built / rejected /
                            // accepted) keep the high-signal trail at
                            // `.info` for default capture; the verbose
                            // dump is opt-in via Console.app debug
                            // streaming when triaging.
                            let txtSummary = txt.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
                            bonjourBrowserDiscoveryLogger.debug("result endpoint=\(endpointDescription, privacy: .public) txt=[\(txtSummary, privacy: .public)]")
                            guard let candidate = HouseholdBonjourBrowser.candidate(from: result) else {
                                bonjourBrowserDiscoveryLogger.info("candidate skipped: candidate(from:) returned nil — required TXT key missing or endpointURL failed")
                                continue
                            }
                            bonjourBrowserDiscoveryLogger.info("candidate built endpoint=\(candidate.endpoint.absoluteString, privacy: .public) householdId=\(candidate.householdId, privacy: .public) pairingState=\(candidate.pairingState, privacy: .public) shortNonce=\(candidate.shortNonce, privacy: .public)")
                            guard candidate.matches(qr: qr) else {
                                bonjourBrowserDiscoveryLogger.info("candidate rejected: matches(qr:) returned false (householdId, pairingState, or shortNonce did not align)")
                                continue
                            }
                            bonjourBrowserDiscoveryLogger.info("candidate accepted — pairing endpoint=\(candidate.endpoint.absoluteString, privacy: .public)")
                            self.finish(.success(candidate))
                            return
                        }
                    }
                    browser.stateUpdateHandler = { state in
                        if case .failed = state {
                            self.finish(.failure(HouseholdPairingError.networkUnavailable))
                        }
                    }
                    browser.start(queue: .global(qos: .userInitiated))
                }
            }

            func finish(_ result: Result<HouseholdDiscoveryCandidate, Error>) {
                let continuation: CheckedContinuation<HouseholdDiscoveryCandidate, Error>?
                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                self.resumed = true
                continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                browser.cancel()
                continuation?.resume(with: result)
            }

            func cancel() {
                finish(.failure(CancellationError()))
            }
        }

        let session = BrowseSession()
        return try await withTaskCancellationHandler {
            try await session.start(for: qr)
        } onCancel: {
            session.cancel()
        }
    }

    private static func candidate(from result: NWBrowser.Result) -> HouseholdDiscoveryCandidate? {
        guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
        let txt = result.metadata.txtRecord ?? [:]
        guard let householdId = txt["hh_id"],
              let pairing = txt["pairing"],
              let nonce = txt["pair_nonce"] else {
            return nil
        }
        guard let endpoint = endpointURL(serviceName: name, domain: domain, txt: txt) else {
            return nil
        }
        return HouseholdDiscoveryCandidate(
            endpoint: endpoint,
            householdId: householdId,
            householdName: txt["hh_name"] ?? name,
            machineId: txt["m_id"],
            pairingState: pairing,
            shortNonce: nonce
        )
    }

    /// `internal` (was `private`) so the FQDN-vs-single-label distinction
    /// added below is unit-testable via `@testable import SoyehtCore`. The
    /// behaviour was previously only exercised end-to-end through a live
    /// Bonjour browse, which let a regression slip into production:
    /// theyos publishes `host=macStudio.local` in TXT, the function then
    /// double-appended `.local` and produced `macStudio.local.local`,
    /// which DNS-SD rejected and surfaced as the user-facing
    /// `household.pairing.error.noMatchingHousehold` after the URLSession
    /// connect failed.
    static func endpointURL(serviceName: String, domain: String, txt: [String: String]) -> URL? {
        if let urlString = txt["url"], let url = URL(string: urlString) {
            return url
        }
        let scheme = txt["scheme"] ?? "http"
        let port = Int(txt["port"] ?? txt["hh_port"] ?? "") ?? 8091
        let domainName = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostDomain = domainName.isEmpty ? "local" : domainName
        let hostLabel = txt["host"] ?? inferredHostLabel(serviceName: serviceName, householdId: txt["hh_id"])
        // The publisher may emit `host` either as a single label
        // (e.g. "casa") that needs the domain appended, or as a
        // fully-qualified mDNS name (e.g. "macStudio.local") which is
        // already complete. Detect by presence of a dot. Without this
        // distinction, "macStudio.local" gets ".local" appended a
        // second time and produces "macStudio.local.local", which does
        // not resolve. theyos `bonjour_publisher.rs::base_txt` uses the
        // raw `gethostname()` which on macOS is `<host>.local`, so the
        // fully-qualified branch is hit on every Mac publisher.
        let host: String
        if hostLabel.contains(".") {
            // Trim ONLY a trailing dot (root-anchored DNS notation,
            // e.g. `macStudio.local.`). Leading-dot inputs
            // (e.g. `.macStudio.local`) are malformed and are passed
            // through unchanged so the resulting URL fails to resolve
            // and the publisher bug surfaces in the discovery log
            // instead of being silently normalised.
            host = hostLabel.hasSuffix(".") ? String(hostLabel.dropLast()) : hostLabel
        } else {
            host = "\(hostLabel).\(hostDomain)"
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        let result = components.url
        bonjourBrowserDiscoveryLogger.info("endpointURL serviceName=\(serviceName, privacy: .public) domain=\(domain, privacy: .public) hostLabel=\(hostLabel, privacy: .public) host=\(host, privacy: .public) url=\(result?.absoluteString ?? "nil", privacy: .public)")
        return result
    }

    private static func inferredHostLabel(serviceName: String, householdId: String?) -> String {
        guard let householdId else { return serviceName }
        let short = householdId
            .replacingOccurrences(of: "hh_", with: "")
            .prefix(8)
        let prefix = "Soyeht-"
        let suffix = "-\(short)"
        if serviceName.hasPrefix(prefix), serviceName.hasSuffix(suffix) {
            let start = serviceName.index(serviceName.startIndex, offsetBy: prefix.count)
            let end = serviceName.index(serviceName.endIndex, offsetBy: -suffix.count)
            if start < end {
                return String(serviceName[start..<end])
            }
        }
        return serviceName
    }
}

public extension PairDeviceQR {
    /// Short form of the pairing nonce that matches the value theyos
    /// publishes in the `pair_nonce` TXT record. The publisher emits
    /// the first 8 CHARS of the base64url-encoded nonce — not the first
    /// 8 BYTES of the raw nonce. 8 base64url chars = 6 raw bytes (since
    /// base64url groups 3 bytes per 4 chars), so the equivalent
    /// byte-prefix is 6, not 8. The previous implementation used 8
    /// bytes and produced an 11-char string, which never matched
    /// theyos's 8-char TXT value, causing every candidate to be
    /// rejected by `matches(qr:)` and surfacing as
    /// `household.pairing.error.noMatchingHousehold` after the
    /// `firstMatchingCandidate` timeout. Story 1 hardware testing
    /// 2026-05-08 confirmed the mismatch directly via `dns-sd -L`
    /// (`pair_nonce=KHR86G0i` = 8 chars, iOS produced 11).
    var shortNonce: String {
        Data(nonce.prefix(6)).soyehtBase64URLEncodedString()
    }
}

private extension NWBrowser.Result.Metadata {
    var txtRecord: [String: String]? {
        guard case .bonjour(let record) = self else { return nil }
        return record.dictionary
    }
}
