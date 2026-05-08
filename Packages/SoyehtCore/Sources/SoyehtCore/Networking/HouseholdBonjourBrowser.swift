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
                        if HouseholdBonjourBrowser.tryAcceptCandidate(in: results, for: qr, sourcePhase: "browseChanged", accept: { self.finish(.success($0)) }) {
                            return
                        }
                        // No candidate matched on the first delivery.
                        // iOS 26.4.1 NWBrowser hardware test 2026-05-08
                        // observed that `result.metadata.txtRecord`
                        // arrives EMPTY on the initial
                        // `browseResultsChangedHandler` callback
                        // (PTR/SRV/A delivered before TXT) and the
                        // handler is NOT re-invoked when the TXT
                        // record subsequently arrives over the wire,
                        // even with the browser still active —
                        // leaving the request to time out as
                        // `noMatchingHousehold` despite the publisher
                        // being correct. Polling re-reads
                        // `result.metadata` at exponentially-spaced
                        // delays in case the metadata accessor is a
                        // dynamic property under the hood. Race-safe
                        // via `BrowseSession.finish` lock + `resumed`
                        // flag — first thread to acquire wins, others
                        // become idempotent.
                        Task { [weak self, results] in
                            // Zero-delay first re-read — sometimes the
                            // struct snapshot already has TXT populated
                            // between callback dispatch and our handler
                            // reading metadata. Cheap to try; if not,
                            // fall through to the exponential backoff.
                            // Suggested by @agente-backend during the
                            // 2026-05-08 hardware test review.
                            await Task.yield()
                            guard let self else { return }
                            self.lock.lock()
                            let alreadyResumedZero = self.resumed
                            self.lock.unlock()
                            if !alreadyResumedZero {
                                bonjourBrowserDiscoveryLogger.debug("metadata poll t=+0ms (next-tick)")
                                if HouseholdBonjourBrowser.tryAcceptCandidate(in: results, for: qr, sourcePhase: "metadataPoll+0ms", accept: { self.finish(.success($0)) }) {
                                    return
                                }
                            }
                            let delaysMs: [UInt64] = [300, 700, 1500, 3000]
                            for delayMs in delaysMs {
                                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                                self.lock.lock()
                                let alreadyResumed = self.resumed
                                self.lock.unlock()
                                if alreadyResumed { return }
                                bonjourBrowserDiscoveryLogger.debug("metadata poll t=+\(delayMs, privacy: .public)ms")
                                if HouseholdBonjourBrowser.tryAcceptCandidate(in: results, for: qr, sourcePhase: "metadataPoll+\(delayMs)ms", accept: { self.finish(.success($0)) }) {
                                    return
                                }
                            }
                            bonjourBrowserDiscoveryLogger.error("metadata poll exhausted; TXT remained unresolved across all delays — likely iOS NWBrowser PTR/SRV-before-TXT race; DNSServiceResolve fallback follows in next PR")
                        }
                    }
                    // Full state coverage so a `.waiting(error)` from
                    // Local Network policy denial, mDNS resolution
                    // failure, or Bonjour service unavailability is
                    // surfaced in the discovery log instead of
                    // silently maturing into a `noMatchingHousehold`
                    // 10s timeout (which is indistinguishable from
                    // "no service published"). Pattern proposed by
                    // super-agente during Story 1 hardware debugging
                    // 2026-05-08 — only `.failed` was previously
                    // observed.
                    browser.stateUpdateHandler = { state in
                        switch state {
                        case .setup:
                            bonjourBrowserDiscoveryLogger.info("browser state=setup")
                        case .ready:
                            bonjourBrowserDiscoveryLogger.info("browser state=ready")
                        case .waiting(let error):
                            bonjourBrowserDiscoveryLogger.error("browser state=waiting error=\(String(describing: error), privacy: .public)")
                        case .failed(let error):
                            bonjourBrowserDiscoveryLogger.error("browser state=failed error=\(String(describing: error), privacy: .public)")
                            self.finish(.failure(HouseholdPairingError.networkUnavailable))
                        case .cancelled:
                            bonjourBrowserDiscoveryLogger.info("browser state=cancelled")
                        @unknown default:
                            bonjourBrowserDiscoveryLogger.error("browser state=unknown \(String(describing: state), privacy: .public)")
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

    /// Iterate the browser's current results, log per-result diagnostics,
    /// and attempt to build + match a candidate. On the first matching
    /// result, calls `accept(candidate)` and returns `true`; if no
    /// result yields a match, returns `false`. Called from
    /// `browseResultsChangedHandler` (sourcePhase=`browseChanged`) and
    /// from the metadata polling task (sourcePhase=`metadataPoll+Nms`)
    /// — both paths share this method so log output and match logic
    /// stay consistent across phases.
    fileprivate static func tryAcceptCandidate(
        in results: Set<NWBrowser.Result>,
        for qr: PairDeviceQR,
        sourcePhase: String,
        accept: (HouseholdDiscoveryCandidate) -> Void
    ) -> Bool {
        for result in results {
            let endpointDescription = String(describing: result.endpoint)
            let txt: [String: String]
            let metadataDescription: String
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
                metadataDescription = "bonjour(\(record.dictionary.count) keys)"
            } else {
                txt = [:]
                metadataDescription = "non-bonjour"
            }
            let txtSummary = txt.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
            bonjourBrowserDiscoveryLogger.debug("phase=\(sourcePhase, privacy: .public) result endpoint=\(endpointDescription, privacy: .public) metadata=\(metadataDescription, privacy: .public) txt=[\(txtSummary, privacy: .public)]")
            guard let candidate = HouseholdBonjourBrowser.candidate(from: result) else {
                continue
            }
            bonjourBrowserDiscoveryLogger.info("phase=\(sourcePhase, privacy: .public) candidate built endpoint=\(candidate.endpoint.absoluteString, privacy: .public) householdId=\(candidate.householdId, privacy: .public) pairingState=\(candidate.pairingState, privacy: .public) shortNonce=\(candidate.shortNonce, privacy: .public)")
            guard candidate.matches(qr: qr) else {
                bonjourBrowserDiscoveryLogger.info("phase=\(sourcePhase, privacy: .public) candidate rejected: matches(qr:) returned false")
                continue
            }
            bonjourBrowserDiscoveryLogger.info("phase=\(sourcePhase, privacy: .public) candidate accepted — pairing endpoint=\(candidate.endpoint.absoluteString, privacy: .public)")
            accept(candidate)
            return true
        }
        return false
    }

    private static func candidate(from result: NWBrowser.Result) -> HouseholdDiscoveryCandidate? {
        // Granular skip-reason logging proposed by super-agente during
        // Story 1 debugging 2026-05-08. Each early-return path now
        // emits a distinct reason so the discovery log can pin which
        // TXT key was missing or whether endpoint construction failed,
        // instead of collapsing into a single ambiguous "candidate=nil".
        guard case let .service(name, _, domain, _) = result.endpoint else {
            bonjourBrowserDiscoveryLogger.info("candidate skipped: endpoint not .service (got \(String(describing: result.endpoint), privacy: .public))")
            return nil
        }
        let txt = result.metadata.txtRecord ?? [:]
        guard let householdId = txt["hh_id"],
              let pairing = txt["pairing"],
              let nonce = txt["pair_nonce"] else {
            let presentKeys = txt.keys.sorted().joined(separator: ",")
            let missing = ["hh_id", "pairing", "pair_nonce"]
                .filter { txt[$0] == nil }
                .joined(separator: ",")
            bonjourBrowserDiscoveryLogger.info("candidate skipped: required TXT key(s) missing=[\(missing, privacy: .public)] presentKeys=[\(presentKeys, privacy: .public)]")
            return nil
        }
        guard let endpoint = endpointURL(serviceName: name, domain: domain, txt: txt) else {
            bonjourBrowserDiscoveryLogger.info("candidate skipped: endpointURL returned nil for serviceName=\(name, privacy: .public) domain=\(domain, privacy: .public)")
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
