import Foundation
import Network

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

    public func matches(qr: PairDeviceQR) -> Bool {
        householdId == qr.householdId
            && pairingState == "open"
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
                        for result in results {
                            guard let candidate = HouseholdBonjourBrowser.candidate(from: result),
                                  candidate.matches(qr: qr) else {
                                continue
                            }
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

    private static func endpointURL(serviceName: String, domain: String, txt: [String: String]) -> URL? {
        if let urlString = txt["url"], let url = URL(string: urlString) {
            return url
        }
        let scheme = txt["scheme"] ?? "http"
        let port = Int(txt["port"] ?? txt["hh_port"] ?? "") ?? 8091
        let domainName = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostDomain = domainName.isEmpty ? "local" : domainName
        let hostLabel = txt["host"] ?? inferredHostLabel(serviceName: serviceName, householdId: txt["hh_id"])
        var components = URLComponents()
        components.scheme = scheme
        components.host = "\(hostLabel).\(hostDomain)"
        components.port = port
        return components.url
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
    var shortNonce: String {
        Data(nonce.prefix(8)).soyehtBase64URLEncodedString()
    }
}

private extension NWBrowser.Result.Metadata {
    var txtRecord: [String: String]? {
        guard case .bonjour(let record) = self else { return nil }
        return record.dictionary
    }
}
