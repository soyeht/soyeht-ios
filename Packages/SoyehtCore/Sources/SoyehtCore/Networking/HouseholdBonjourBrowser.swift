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
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func browse(for qr: PairDeviceQR) async throws -> HouseholdDiscoveryCandidate {
        try await withCheckedThrowingContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_soyeht-household._tcp", domain: nil),
                using: .tcp
            )
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }
            let box = Box()

            @Sendable func finish(_ result: Result<HouseholdDiscoveryCandidate, Error>) {
                box.lock.lock()
                defer { box.lock.unlock() }
                guard !box.resumed else { return }
                box.resumed = true
                browser.cancel()
                continuation.resume(with: result)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard let candidate = candidate(from: result), candidate.matches(qr: qr) else {
                        continue
                    }
                    finish(.success(candidate))
                    return
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    finish(.failure(HouseholdPairingError.networkUnavailable))
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
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
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
        let host = "\(encodedName).\(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
        let endpoint = URL(string: "https://\(host):8443") ?? URL(string: "https://\(encodedName).local:8443")!
        return HouseholdDiscoveryCandidate(
            endpoint: endpoint,
            householdId: householdId,
            householdName: txt["hh_name"] ?? name,
            machineId: txt["m_id"],
            pairingState: pairing,
            shortNonce: nonce
        )
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
