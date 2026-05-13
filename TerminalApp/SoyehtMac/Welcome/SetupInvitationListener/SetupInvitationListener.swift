import Foundation
import OSLog
import SoyehtCore

private let setupInvitationLogger = Logger(subsystem: "com.soyeht.mac", category: "SetupInvitation")

/// Mac-side setup-invitation listener (T070).
///
/// On first launch, before showing HouseNamingView, browses `_soyeht-setup._tcp.`
/// on Tailnet via SetupInvitationBrowser. If an invitation is found within the
/// timeout window, claims the token via POST /bootstrap/claim-setup-invitation and
/// skips the naming UI (iPhone will provide the name via POST /bootstrap/initialize).
final class SetupInvitationListener: @unchecked Sendable {
    enum Outcome: Sendable {
        case invitationClaimed(ownerDisplayName: String?, iphoneApnsToken: Data?)
        case notFound
        case failed(Error)
    }

    private let engineBaseURL: URL
    private let browser: SetupInvitationBrowser
    private let claimClient: SetupInvitationClaimClient
    private let existingHouse: SetupInvitationExistingHouse?

    private static let discoveryTimeout: TimeInterval = 5.0

    init(engineBaseURL: URL, existingHouse: SetupInvitationExistingHouse? = nil) {
        self.engineBaseURL = engineBaseURL
        self.existingHouse = existingHouse
        self.browser = SetupInvitationBrowser()
        self.claimClient = SetupInvitationClaimClient(baseURL: engineBaseURL)
    }

    /// Browses for a setup invitation; every exit path stops the browser.
    func listen() async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await self.listenViaBonjour() }
            group.addTask { await self.listenViaTailscalePeerProbe() }

            var firstFailure: Outcome?
            while let outcome = await group.next() {
                switch outcome {
                case .invitationClaimed:
                    group.cancelAll()
                    browser.stop()
                    return outcome
                case .failed:
                    if firstFailure == nil {
                        firstFailure = outcome
                    }
                case .notFound:
                    break
                }
            }
            return firstFailure ?? .notFound
        }
    }

    private func listenViaBonjour() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let gate = ResumeOnce()

                let finish: @Sendable (Outcome) -> Void = { [browser] outcome in
                    guard gate.claim() else { return }
                    browser.stop()
                    continuation.resume(returning: outcome)
                }

                browser.onStateChange = { [claimClient] state in
                    switch state {
                    case .discovered(let payload):
                        Task {
                            do {
                                _ = try await claimClient.claim(
                                    token: payload.token,
                                    ownerDisplayName: payload.ownerDisplayName,
                                    iphoneApnsToken: payload.iphoneApnsToken
                                )
                                finish(.invitationClaimed(
                                    ownerDisplayName: payload.ownerDisplayName,
                                    iphoneApnsToken: payload.iphoneApnsToken
                                ))
                            } catch {
                                finish(.failed(error))
                            }
                        }
                    case .failed(let message):
                        finish(.failed(ListenerError.browserFailed(message)))
                    case .idle, .browsing, .stopped:
                        break
                    }
                }

                browser.start()

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + Self.discoveryTimeout
                ) {
                    finish(.notFound)
                }
            }
        } onCancel: { [browser] in
            browser.stop()
        }
    }

    private func listenViaTailscalePeerProbe() async -> Outcome {
        setupInvitationLogger.info("direct_probe.start")
        let deadline = Date().addingTimeInterval(Self.discoveryTimeout)

        repeat {
            do {
                let remaining = max(0.25, min(1.0, deadline.timeIntervalSinceNow))
                guard let hit = await SetupInvitationDirectProbe.findFirstInvitation(
                    timeout: remaining
                ) else {
                    continue
                }
                setupInvitationLogger.info("direct_probe.invitation_found iphone=\(hit.iphoneBaseURL.absoluteString, privacy: .public)")
	                do {
	                    _ = try await claimClient.claim(
	                        token: hit.payload.token,
	                        ownerDisplayName: hit.payload.ownerDisplayName,
	                        iphoneApnsToken: hit.payload.iphoneApnsToken,
	                        iphoneEndpoint: hit.iphoneBaseURL,
	                        iphoneAddresses: hit.iphoneAddresses,
	                        expiresAt: hit.payload.expiresAt
	                    )
	                    setupInvitationLogger.info("direct_probe.claimed")
	                } catch {
	                    guard SetupInvitationDirectProbe.shouldProceedAfterClaimFailure(error) else {
	                        throw error
	                    }
	                    setupInvitationLogger.info("direct_probe.claim_skipped_continuing error=\(String(describing: error), privacy: .public)")
	                }
                if let macEngineURL = await SetupInvitationDirectProbe.reachableMacEngineURL(
                    localEngineBaseURL: engineBaseURL
                ) {
                    let localPairing = await SetupInvitationDirectProbe.makeMacLocalPairing(
                        payload: hit.payload,
                        macEngineURL: macEngineURL
                    )
                    try? await SetupInvitationDirectProbe.notifyClaimed(
                        iphoneBaseURL: hit.iphoneBaseURL,
                        claim: SetupInvitationDirectClaim(
                            token: hit.payload.token,
                            macEngineURL: macEngineURL,
                            macLocalPairing: localPairing,
                            existingHouse: existingHouse
                        )
                    )
                    setupInvitationLogger.info("direct_probe.notified iphone=\(hit.iphoneBaseURL.absoluteString, privacy: .public) mac=\(macEngineURL.absoluteString, privacy: .public)")
                }
                return .invitationClaimed(
                    ownerDisplayName: hit.payload.ownerDisplayName,
                    iphoneApnsToken: hit.payload.iphoneApnsToken
                )
            } catch is CancellationError {
                return .notFound
            } catch {
                setupInvitationLogger.error("direct_probe.failed \(String(describing: error), privacy: .public)")
                return .failed(error)
            }
        } while Date() < deadline

        setupInvitationLogger.info("direct_probe.not_found")
        return .notFound
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Atomically claims the gate. Returns true only on the first call.
    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}

private enum ListenerError: Error, LocalizedError {
    case browserFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserFailed(let message):
            return message
        }
    }
}

private enum SetupInvitationDirectProbe {
    struct Hit: Sendable {
        let payload: SetupInvitationPayload
        let iphoneBaseURL: URL
        let iphoneAddresses: [String]
    }

    private struct Candidate: Sendable {
        let baseURL: URL
        let addresses: [String]
    }

    static func findFirstInvitation(timeout: TimeInterval) async -> Hit? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !Task.isCancelled else { return nil }
            let candidates = await tailscaleStatus().map(candidateIPhoneBaseURLs) ?? []
            setupInvitationLogger.info("direct_probe.candidates count=\(candidates.count, privacy: .public)")
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                let baseURL = candidate.baseURL
                setupInvitationLogger.info("direct_probe.fetch \(baseURL.absoluteString, privacy: .public)")
                if let hit = await fetchInvitation(from: baseURL, addresses: candidate.addresses) {
                    return hit
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return nil
    }

    static func reachableMacEngineURL(localEngineBaseURL: URL) async -> URL? {
        guard let status = await tailscaleStatus(),
              let node = status.selfNode else {
            return localEngineBaseURL
        }
        let port = localEngineBaseURL.port ?? 8091
        if let dnsName = normalizedDNSName(node.dnsName),
           let url = URL(string: "http://\(dnsName):\(port)") {
            return url
        }
        if let ip = node.tailscaleIPs.first(where: isTailscaleIPv4),
           let url = URL(string: "http://\(ip):\(port)") {
            return url
        }
        return localEngineBaseURL
    }

    static func notifyClaimed(iphoneBaseURL: URL, claim: SetupInvitationDirectClaim) async throws {
        let url = iphoneBaseURL.appendingPathComponent(String(SetupInvitationDirectEndpoint.claimedPath.dropFirst()))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try claim.encodedData()
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DirectProbeError.claimNotificationFailed
        }
    }

    @MainActor
    static func makeMacLocalPairing(
        payload: SetupInvitationPayload,
        macEngineURL: URL
    ) async -> SetupInvitationMacLocalPairing? {
        guard let deviceID = payload.iphoneDeviceID else {
            setupInvitationLogger.info("direct_probe.local_pairing_skipped missing_iphone_device_id")
            return nil
        }
        guard let ports = await waitForPairingPorts() else {
            setupInvitationLogger.info("direct_probe.local_pairing_skipped missing_presence_ports")
            return nil
        }
        guard let host = macEngineURL.host, !host.isEmpty else {
            setupInvitationLogger.info("direct_probe.local_pairing_skipped missing_mac_host")
            return nil
        }

        let name = payload.iphoneDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = payload.iphoneDeviceModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
        let deviceModel = model.flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
        let secret = PairingStore.shared.pair(
            deviceID: deviceID,
            name: deviceName,
            model: deviceModel
        )
        setupInvitationLogger.info("direct_probe.local_pairing_created device=\(deviceID.uuidString, privacy: .public) host=\(host, privacy: .public)")
        return SetupInvitationMacLocalPairing(
            macID: PairingStore.shared.macID,
            macName: PairingStore.shared.macName,
            host: host,
            presencePort: ports.presencePort,
            attachPort: ports.attachPort,
            secret: secret
        )
    }

    @MainActor
    private static func waitForPairingPorts() async -> (presencePort: Int, attachPort: Int)? {
        for _ in 0..<30 {
            if let presencePort = PairingPresenceServer.shared.presencePort,
               let attachPort = PairingPresenceServer.shared.attachPort {
                return (Int(presencePort), Int(attachPort))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

	    private static func fetchInvitation(from baseURL: URL, addresses: [String]) async -> Hit? {
	        let url = baseURL.appendingPathComponent(String(SetupInvitationDirectEndpoint.invitationPath.dropFirst()))
	        var request = URLRequest(url: url)
	        request.httpMethod = "GET"
	        request.timeoutInterval = 1.0
	        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
	            let (data, response) = try await URLSession.shared.data(for: request)
	            guard let http = response as? HTTPURLResponse,
	                  http.statusCode == 200 else {
	                return nil
	            }
	            let payload = try SetupInvitationPayload.decodeDirectEndpointData(data)
	            return Hit(payload: payload, iphoneBaseURL: baseURL, iphoneAddresses: addresses)
	        } catch {
	            return nil
	        }
	    }

	    fileprivate static func shouldProceedAfterClaimFailure(_ error: Error) -> Bool {
	        guard case BootstrapError.serverError(let code, _) = error else { return false }
	        return [
	            "invitation_not_recognized",
	            "invalid_state",
	            "already_initialized",
	            "already_named",
	        ].contains(code)
	    }

    private static func candidateIPhoneBaseURLs(from status: TailscaleStatus) -> [Candidate] {
        var seen = Set<String>()
        var candidates: [Candidate] = []

        func append(host: String, addresses: [String]) {
            guard !host.isEmpty, seen.insert(host).inserted else { return }
            guard let url = URL(string: "http://\(host):\(SetupInvitationPublisher.directPort)") else { return }
            candidates.append(Candidate(baseURL: url, addresses: addresses))
        }

        for node in status.peers.values where node.online == true {
            guard node.os?.lowercased() == "ios" else { continue }
            let addresses = node.tailscaleIPs.filter(isTailscaleIPv4)
            if let dnsName = normalizedDNSName(node.dnsName) {
                append(host: dnsName, addresses: addresses)
            }
            for ip in addresses {
                append(host: ip, addresses: addresses)
            }
        }

        return candidates
    }

    private static func tailscaleStatus() async -> TailscaleStatus? {
        guard let binary = tailscaleBinary() else { return nil }
        guard let data = await run(binary, arguments: ["status", "--json"], timeout: 2.0) else { return nil }
        return try? JSONDecoder().decode(TailscaleStatus.self, from: data)
    }

    private static func tailscaleBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let output = Pipe()
            let errorOutput = Pipe()
            process.standardOutput = output
            process.standardError = errorOutput

            let gate = ResumeOnce()
            process.terminationHandler = { _ in
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                if gate.claim() {
                    continuation.resume(returning: data)
                }
            }

            do {
                try process.run()
            } catch {
                if gate.claim() {
                    continuation.resume(returning: nil)
                }
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
                if gate.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func normalizedDNSName(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isTailscaleIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}

private struct TailscaleStatus: Decodable {
    let selfNode: TailscaleNode?
    let peers: [String: TailscaleNode]

    enum CodingKeys: String, CodingKey {
        case selfNode = "Self"
        case peers = "Peer"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selfNode = try container.decodeIfPresent(TailscaleNode.self, forKey: .selfNode)
        peers = try container.decodeIfPresent([String: TailscaleNode].self, forKey: .peers) ?? [:]
    }
}

private struct TailscaleNode: Decodable {
    let dnsName: String?
    let tailscaleIPs: [String]
    let online: Bool?
    let os: String?

    enum CodingKeys: String, CodingKey {
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
        case os = "OS"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dnsName = try container.decodeIfPresent(String.self, forKey: .dnsName)
        tailscaleIPs = try container.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
        online = try container.decodeIfPresent(Bool.self, forKey: .online)
        os = try container.decodeIfPresent(String.self, forKey: .os)
    }
}

private enum DirectProbeError: Error {
    case claimNotificationFailed
}
