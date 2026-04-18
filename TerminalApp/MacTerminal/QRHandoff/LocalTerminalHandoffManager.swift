import Darwin
import Foundation
import Network
import os

private let localHandoffLogger = Logger(subsystem: "com.soyeht.mac", category: "local-handoff")
private let localHandoffTokenLifetime: TimeInterval = 5 * 60

@MainActor
final class LocalTerminalHandoffManager {
    struct GeneratedHandoff {
        let deepLink: String
        let expiresAt: String
        let isPending: @Sendable () async -> Bool
    }

    static let shared = LocalTerminalHandoffManager()

    private var sessions: [UUID: Session] = [:]

    func generateHandoff(
        conversationID: UUID,
        title: String,
        terminalView: MacOSWebSocketTerminalView
    ) async throws -> GeneratedHandoff {
        invalidate(conversationID: conversationID)

        let session = try Session(
            conversationID: conversationID,
            title: title,
            terminalView: terminalView
        )
        session.installOutputObserver()
        session.onTerminate = { [weak self] id in
            Task { @MainActor in
                guard let self,
                      self.sessions[id] === session else { return }
                self.sessions.removeValue(forKey: id)
            }
        }
        sessions[conversationID] = session
        return try await session.start()
    }

    func invalidate(conversationID: UUID) {
        sessions.removeValue(forKey: conversationID)?.cancel()
    }
}

private final class Session {
    typealias ID = UUID

    private struct Client {
        let id: UUID
        let connection: NWConnection
        var authenticated: Bool
    }

    private let conversationID: ID
    private let title: String
    private weak var terminalView: MacOSWebSocketTerminalView?
    private let queue: DispatchQueue
    private let token: String
    private let expiresAt: Date

    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var outputObserverID: UUID?
    private var didAuthenticate = false
    private var readyContinuation: CheckedContinuation<LocalTerminalHandoffManager.GeneratedHandoff, Error>?
    private var startFinished = false
    private var hasExpired = false
    private var expiryTimer: DispatchSourceTimer?

    var onTerminate: ((ID) -> Void)?

    init(
        conversationID: ID,
        title: String,
        terminalView: MacOSWebSocketTerminalView
    ) throws {
        self.conversationID = conversationID
        self.title = title
        self.terminalView = terminalView
        self.queue = DispatchQueue(label: "com.soyeht.mac.local-handoff.\(conversationID.uuidString)")
        self.token = Self.makeToken()
        self.expiresAt = Date().addingTimeInterval(localHandoffTokenLifetime)

        let wsOptions = NWProtocolWebSocket.Options(.version13)
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1_048_576
        wsOptions.setClientRequestHandler(queue) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
    }

    deinit {
        expiryTimer?.cancel()
    }

    func start() async throws -> LocalTerminalHandoffManager.GeneratedHandoff {
        guard let listener else {
            throw NSError(domain: "LocalTerminalHandoff", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Listener local indisponível."
            ])
        }

        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        startExpiryTimer()

        return try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
        }
    }

    @MainActor
    func installOutputObserver() {
        guard outputObserverID == nil else { return }
        outputObserverID = terminalView?.addLocalOutputObserver { [weak self] data in
            self?.broadcast(data)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.expiryTimer?.cancel()
            self.expiryTimer = nil
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values {
                client.connection.cancel()
            }
            self.clients.removeAll()
            if let observerID = self.outputObserverID {
                Task { @MainActor [weak self] in
                    self?.terminalView?.removeLocalOutputObserver(observerID)
                }
                self.outputObserverID = nil
            }
            if let continuation = self.readyContinuation {
                self.readyContinuation = nil
                continuation.resume(throwing: NSError(
                    domain: "LocalTerminalHandoff",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Handoff local cancelado."]
                ))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTerminate?(self.conversationID)
            }
        }
    }

    func pendingStatus() async -> Bool {
        queue.sync { !didAuthenticate && !hasExpired }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            completeStartIfNeeded()
        case .failed(let error):
            failStartIfNeeded(error)
            localHandoffLogger.error("local handoff listener failed: \(error.localizedDescription, privacy: .public)")
            cancel()
        case .cancelled:
            failStartIfNeeded(NSError(
                domain: "LocalTerminalHandoff",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Listener local cancelado."]
            ))
        default:
            break
        }
    }

    private func completeStartIfNeeded() {
        guard !startFinished,
              let listener,
              let port = listener.port?.rawValue,
              let continuation = readyContinuation else { return }
        startFinished = true
        readyContinuation = nil

        let wsCandidates = candidateWebSocketURLs(port: port)
        let deepLink = makeDeepLink(wsCandidates: wsCandidates, port: port)
        continuation.resume(returning: .init(
            deepLink: deepLink,
            expiresAt: isoTimestamp(expiresAt),
            isPending: { [weak self] in await self?.pendingStatus() ?? false }
        ))
    }

    private func failStartIfNeeded(_ error: Error) {
        guard !startFinished,
              let continuation = readyContinuation else { return }
        startFinished = true
        readyContinuation = nil
        continuation.resume(throwing: error)
    }

    private func accept(_ connection: NWConnection) {
        let clientID = UUID()
        clients[clientID] = Client(id: clientID, connection: connection, authenticated: false)

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, clientID: clientID)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, clientID: UUID) {
        switch state {
        case .ready:
            receive(on: clientID)
        case .failed(let error):
            localHandoffLogger.error("local handoff connection failed: \(error.localizedDescription, privacy: .public)")
            dropClient(clientID)
        case .cancelled:
            dropClient(clientID)
        default:
            break
        }
    }

    private func receive(on clientID: UUID) {
        guard let client = clients[clientID] else { return }
        client.connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                self.dropClient(clientID)
                return
            }

            guard let wsMetadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                self.receive(on: clientID)
                return
            }

            switch wsMetadata.opcode {
            case .binary:
                if let content, self.clients[clientID]?.authenticated == true {
                    Task { @MainActor [weak self] in
                        self?.terminalView?.writeToLocalSession(content)
                    }
                }
            case .text:
                if let content, let text = String(data: content, encoding: .utf8) {
                    self.handleTextMessage(text, from: clientID)
                }
            case .close:
                self.dropClient(clientID)
                return
            default:
                break
            }

            self.receive(on: clientID)
        }
    }

    private func handleTextMessage(_ text: String, from clientID: UUID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "local_handoff_auth":
            guard let candidate = json["token"] as? String,
                  candidate == token,
                  Date() < expiresAt else {
                sendClose(to: clientID, code: .protocolCode(.policyViolation))
                return
            }
            if var client = clients[clientID] {
                client.authenticated = true
                clients[clientID] = client
            }
            didAuthenticate = true
            sendJSON(["type": "local_handoff_ready", "title": title], to: clientID)
            if let snapshot = terminalView?.localReplaySnapshot(), !snapshot.isEmpty {
                sendBinary(snapshot, to: clientID)
            }
        case "input":
            guard clients[clientID]?.authenticated == true,
                  let value = json["data"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.terminalView?.writeToLocalSession(Data(value.utf8))
            }
        case "resize":
            guard clients[clientID]?.authenticated == true,
                  let cols = json["cols"] as? Int,
                  let rows = json["rows"] as? Int else { return }
            Task { @MainActor [weak self] in
                self?.terminalView?.resizeLocalSession(cols: cols, rows: rows)
            }
        default:
            break
        }
    }

    private func broadcast(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            let authenticated = self.clients.values.filter(\.authenticated).map(\.id)
            for clientID in authenticated {
                self.sendBinary(data, to: clientID)
            }
        }
    }

    private func sendBinary(_ data: Data, to clientID: UUID) {
        guard let client = clients[clientID] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "local-handoff-binary", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendJSON(_ object: [String: Any], to clientID: UUID) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let client = clients[clientID] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "local-handoff-json", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendClose(to clientID: UUID, code: NWProtocolWebSocket.CloseCode) {
        guard let client = clients[clientID] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "local-handoff-close", metadata: [metadata])
        client.connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func dropClient(_ clientID: UUID) {
        clients.removeValue(forKey: clientID)
        if hasExpired && clients.values.filter(\.authenticated).isEmpty {
            cancel()
        }
    }

    private func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + localHandoffTokenLifetime)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.hasExpired = true
            if self.clients.values.filter(\.authenticated).isEmpty {
                self.cancel()
            }
        }
        expiryTimer = timer
        timer.resume()
    }

    private func candidateWebSocketURLs(port: UInt16) -> [String] {
        let tokenItem = URLQueryItem(name: "handoff_token", value: token)
        var urls: [String] = []
        for host in candidateHosts() {
            var components = URLComponents()
            components.scheme = "ws"
            components.host = host
            components.port = Int(port)
            components.path = "/local-handoff"
            components.queryItems = [tokenItem]
            if let value = components.string {
                urls.append(value)
            }
        }
        return urls
    }

    private func makeDeepLink(wsCandidates: [String], port: UInt16) -> String {
        let hostValue = candidateHosts().first.map { "http://\($0):\(port)" } ?? "http://localhost:\(port)"
        var components = URLComponents()
        components.scheme = "theyos"
        components.host = "connect"

        var items: [URLQueryItem] = [
            .init(name: "token", value: token),
            .init(name: "host", value: hostValue),
            .init(name: "local_handoff", value: "mac_local"),
            .init(name: "title", value: title),
        ]
        items.append(contentsOf: wsCandidates.map { URLQueryItem(name: "ws_url", value: $0) })
        components.queryItems = items
        return components.string ?? "theyos://connect?token=\(token)&host=\(hostValue)"
    }

    private func candidateHosts() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        func append(_ value: String?) {
            guard let value, !value.isEmpty, seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        for address in Self.privateIPv4Addresses() {
            append(address)
        }

        let rawHost = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawHost.isEmpty {
            append(rawHost)
            if !rawHost.contains(".") {
                append("\(rawHost).local")
            }
        }

        return ordered
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func makeToken() -> String {
        Data((0..<24).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func privateIPv4Addresses() -> [String] {
        var result: [(priority: Int, value: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            let resultCode = getnameinfo(
                address,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard resultCode == 0 else { continue }

            let value = String(cString: host)
            guard !value.hasPrefix("169.254.") else { continue }
            result.append((priority(for: value), value))
        }

        return result
            .sorted {
                if $0.priority == $1.priority {
                    return $0.value < $1.value
                }
                return $0.priority < $1.priority
            }
            .map(\.value)
    }

    private static func priority(for host: String) -> Int {
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return 0
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return 0
            }
        }
        if host.hasPrefix("100.") {
            return 1
        }
        return 2
    }
}
