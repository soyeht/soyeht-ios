import Foundation
@testable import SoyehtCore

/// In-process Nostr relay for tests. Routes NIP-01 frames between
/// any number of connected `InProcessWSSTransport` pairs. The
/// production claim submitter and the test "engine" both connect
/// through the same relay so the test exercises the SAME
/// envelope / encryption / event-signing / ack-handling code that
/// ships in production.
///
/// Behaviour modelled on a real NIP-01 relay:
/// - Events are stored on receipt and forwarded to any active
///   subscription whose filter matches.
/// - A new subscription receives stored events that match its
///   filter BEFORE EOSE (this is what makes the "engine offline at
///   tap" scenario testable: claim is stored; engine subscribes
///   later; relay replays).
/// - Every published event emits an OK frame back to the publisher.
actor MockNostrRelay {
    private final class Connection {
        let transport: InProcessWSSTransport
        var subscriptions: [String: [String: Any]] = [:]
        init(transport: InProcessWSSTransport) { self.transport = transport }
    }

    private final class WeakConnection {
        weak var value: Connection?
        init(_ c: Connection) { self.value = c }
    }

    private var connections: [Connection] = []
    private var events: [NostrEvent] = []
    private var serverTasks: [Task<Void, Never>] = []

    /// Build a new connection. Returns the client-side transport
    /// the test plugs into a `NostrWSSClient`.
    func accept() async -> any NostrWireTransport {
        let pair = await InProcessWSSTransport.makePair()
        let connection = Connection(transport: pair.server)
        connections.append(connection)
        let weakConn = WeakConnection(connection)
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runConnection(weakConn)
        }
        serverTasks.append(task)
        return pair.client
    }

    func shutdown() async {
        for t in serverTasks { t.cancel() }
        for c in connections { await c.transport.close() }
        connections.removeAll()
        events.removeAll()
        serverTasks.removeAll()
    }

    private func runConnection(_ weak: WeakConnection) async {
        guard let connection = weak.value else { return }
        let transport = connection.transport
        while !Task.isCancelled {
            guard let text = try? await transport.recv() else { return }
            await handleFrame(connection: connection, frame: text)
        }
    }

    private func handleFrame(connection: Connection, frame: String) async {
        guard let data = frame.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let arr = raw as? [Any], !arr.isEmpty,
              let kind = arr[0] as? String
        else { return }

        switch kind {
        case "REQ":
            guard arr.count >= 3,
                  let subId = arr[1] as? String,
                  let filter = arr[2] as? [String: Any] else { return }
            connection.subscriptions[subId] = filter
            // Replay stored events matching the filter.
            for event in events where Self.event(event, matches: filter) {
                let frame = try? Self.encodeFrame(["EVENT", subId, event.toJSON()])
                if let frame { try? await connection.transport.send(frame) }
            }

        case "EVENT":
            guard arr.count >= 2,
                  let evJSON = arr[1] as? [String: Any],
                  let event = NostrEvent.fromJSON(evJSON) else { return }
            events.append(event)
            // OK back to publisher.
            if let ok = try? Self.encodeFrame(["OK", event.id, true, ""]) {
                try? await connection.transport.send(ok)
            }
            // Forward to every active subscription that matches.
            for conn in connections {
                for (subId, filter) in conn.subscriptions {
                    guard Self.event(event, matches: filter) else { continue }
                    if let evFrame = try? Self.encodeFrame(["EVENT", subId, event.toJSON()]) {
                        try? await conn.transport.send(evFrame)
                    }
                }
            }

        default:
            break
        }
    }

    private static func encodeFrame(_ value: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Minimal NIP-01 filter matcher — covers `kinds`, `#p` tag,
    /// and `since` because that's what the claw-share submitter +
    /// the engine claim consumer use. Extend on demand.
    private static func event(_ event: NostrEvent, matches filter: [String: Any]) -> Bool {
        if let kinds = filter["kinds"] as? [Int] {
            if !kinds.contains(Int(event.kind)) { return false }
        }
        if let pTags = filter["#p"] as? [String] {
            let eventP = event.tags.compactMap { tag -> String? in
                guard tag.count >= 2, tag[0] == "p" else { return nil }
                return tag[1]
            }
            if !eventP.contains(where: pTags.contains) { return false }
        }
        if let since = filter["since"] as? Int {
            if event.createdAt < UInt64(since) { return false }
        }
        return true
    }
}
