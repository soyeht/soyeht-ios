import Foundation
import Darwin
import Network
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
        if existingHouse != nil {
            return await listenViaTailscalePeerProbe()
        }

        return await withTaskGroup(of: Outcome.self) { group in
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
                    try await SetupInvitationDirectProbe.notifyClaimed(
                        iphoneBaseURL: hit.iphoneBaseURL,
                        claim: SetupInvitationDirectClaim(
                            token: hit.payload.token,
                            macEngineURL: macEngineURL,
                            macLocalPairing: localPairing,
                            existingHouse: existingHouse
                        )
                    )
                    setupInvitationLogger.info("direct_probe.notified iphone=\(hit.iphoneBaseURL.absoluteString, privacy: .public) mac=\(macEngineURL.absoluteString, privacy: .public)")
                } else if existingHouse != nil {
                    setupInvitationLogger.info("direct_probe.claim_skipped_no_reachable_mac_for_existing_house")
                    continue
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

    static func findFirstInvitation(
        timeout: TimeInterval
    ) async -> Hit? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !Task.isCancelled else { return nil }
            let candidates = await candidateIPhoneBaseURLs(timeout: min(1.0, deadline.timeIntervalSinceNow))
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
            return localNetworkMacEngineURL(port: localEngineBaseURL.port ?? 8091) ?? localEngineBaseURL
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
        let response = try await DirectProbeHTTPClient.request(
            method: "POST",
            url: url,
            body: try claim.encodedData(),
            contentType: "application/json",
            timeout: 1.5
        )
        guard (200..<300).contains(response.statusCode) else {
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
        let secret = PairingStore.shared.ensurePairing(
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
        do {
            let response = try await DirectProbeHTTPClient.request(
                method: "GET",
                url: url,
                accept: "application/json",
                timeout: 1.0
            )
            guard response.statusCode == 200 else {
                return nil
            }
            let payload = try SetupInvitationPayload.decodeDirectEndpointData(response.body)
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

    private static func candidateIPhoneBaseURLs(timeout: TimeInterval) async -> [Candidate] {
        let tailscale = await tailscaleStatus().map(candidateTailscaleIPhoneBaseURLs) ?? []
        let bonjour = await localBonjourIPhoneBaseURLs(timeout: timeout)
        return deduplicatedCandidates(tailscale + bonjour)
    }

    private static func candidateTailscaleIPhoneBaseURLs(from status: TailscaleStatus) -> [Candidate] {
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

    private static func localBonjourIPhoneBaseURLs(timeout: TimeInterval) async -> [Candidate] {
        let dnsSD = "/usr/bin/dns-sd"
        guard FileManager.default.isExecutableFile(atPath: dnsSD) else { return [] }
        guard let browseData = await run(
            dnsSD,
            arguments: ["-B", "_soyeht-setup._tcp.", "local."],
            timeout: max(0.25, min(0.8, timeout))
        ) else {
            return []
        }
        let serviceNames = parseBonjourBrowseServiceNames(from: browseData)
        var candidates: [Candidate] = []
        for serviceName in serviceNames {
            guard let resolveData = await run(
                dnsSD,
                arguments: ["-L", serviceName, "_soyeht-setup._tcp.", "local."],
                timeout: 0.8
            ) else {
                continue
            }
            candidates.append(contentsOf: parseBonjourResolveCandidates(from: resolveData))
        }
        return deduplicatedCandidates(candidates)
    }

    private static func parseBonjourBrowseServiceNames(from data: Data) -> [String] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.contains(" Add "), let range = line.range(of: "_soyeht-setup._tcp.") else {
                continue
            }
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    private static func parseBonjourResolveCandidates(from data: Data) -> [Candidate] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var candidates: [Candidate] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let range = line.range(of: " can be reached at ") else { continue }
            let tail = line[range.upperBound...]
            guard let hostPort = tail.split(separator: " ").first,
                  let colon = hostPort.lastIndex(of: ":") else {
                continue
            }
            let host = String(hostPort[..<colon])
            let port = String(hostPort[hostPort.index(after: colon)...])
            guard !host.isEmpty, UInt16(port) != nil,
                  let url = URL(string: "http://\(host):\(port)") else {
                continue
            }
            candidates.append(Candidate(baseURL: url, addresses: [host]))
        }
        return candidates
    }

    private static func deduplicatedCandidates(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            guard let host = candidate.baseURL.host, seen.insert(host).inserted else { return false }
            return true
        }
    }

    private static func localNetworkMacEngineURL(port: Int) -> URL? {
        let ips = localNetworkIPv4Addresses()
        guard let ip = ips.first else { return nil }
        return URL(string: "http://\(ip):\(port)")
    }

    private static func localNetworkIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var values: [(rank: Int, ip: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let ip = String(cString: buffer)
            guard isLANReachableIPv4(ip) else { continue }
            let rank = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            values.append((rank, ip))
        }
        return values.sorted { lhs, rhs in lhs.rank < rhs.rank }.map(\.ip)
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

    private static func isLANReachableIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 0 || parts[0] == 127 { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }
        if isTailscaleIPv4(value) { return false }
        return true
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
    case invalidEndpoint
    case invalidResponse
    case timedOut
}

private struct DirectProbeHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

private enum DirectProbeHTTPClient {
    static func request(
        method: String,
        url: URL,
        body: Data = Data(),
        contentType: String? = nil,
        accept: String? = nil,
        timeout: TimeInterval
    ) async throws -> DirectProbeHTTPResponse {
        guard let host = url.host,
              let portValue = url.port ?? defaultPort(for: url),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw DirectProbeError.invalidEndpoint
        }

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: port,
                using: NWParameters.tcp
            )
            let queue = DispatchQueue(label: "com.soyeht.setup-invitation.direct-http")
            let gate = ResumeOnce()

            let finish: @Sendable (Result<DirectProbeHTTPResponse, Error>) -> Void = { result in
                guard gate.claim() else { return }
                connection.cancel()
                switch result {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sendRequest(
                        method: method,
                        url: url,
                        host: host,
                        body: body,
                        contentType: contentType,
                        accept: accept,
                        on: connection,
                        finish: finish
                    )
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)
            receiveResponse(on: connection, buffer: Data(), finish: finish)

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(DirectProbeError.timedOut))
            }
        }
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func sendRequest(
        method: String,
        url: URL,
        host: String,
        body: Data,
        contentType: String?,
        accept: String?,
        on connection: NWConnection,
        finish: @escaping @Sendable (Result<DirectProbeHTTPResponse, Error>) -> Void
    ) {
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            target += "?\(query)"
        }

        var headers = [
            "\(method) \(target) HTTP/1.1",
            "Host: \(host)",
            "Connection: close",
            "Content-Length: \(body.count)",
        ]
        if let accept {
            headers.append("Accept: \(accept)")
        }
        if let contentType {
            headers.append("Content-Type: \(contentType)")
        }
        headers.append("")
        headers.append("")

        var request = Data(headers.joined(separator: "\r\n").utf8)
        request.append(body)
        connection.send(content: request, completion: .contentProcessed { error in
            if let error {
                finish(.failure(error))
            }
        })
    }

    private static func receiveResponse(
        on connection: NWConnection,
        buffer: Data,
        finish: @escaping @Sendable (Result<DirectProbeHTTPResponse, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error {
                finish(.failure(error))
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let response = parseResponse(nextBuffer) {
                finish(.success(response))
                return
            }
            if isComplete {
                finish(.failure(DirectProbeError.invalidResponse))
                return
            }
            receiveResponse(on: connection, buffer: nextBuffer, finish: finish)
        }
    }

    private static func parseResponse(_ data: Data) -> DirectProbeHTTPResponse? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            return nil
        }

        let contentLength = lines.dropFirst().reduce(into: 0) { length, line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = contentLength == 0
            ? Data()
            : Data(data[bodyStart..<(bodyStart + contentLength)])
        return DirectProbeHTTPResponse(statusCode: statusCode, body: body)
    }
}
