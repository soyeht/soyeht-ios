import Foundation
import CryptoKit
import P256K

/// Minimal Nostr-over-WSS client used by the friend's iOS app to
/// publish encrypted claim events and subscribe to acks.
///
/// Scope is intentionally narrow: connect → subscribe → publish →
/// wait-for-ack → close. Multi-relay strategies, NIP-15 EOSE
/// handling, and historical-event backfill are caller concerns. The
/// claim flow only needs one relay round-trip per claim.
///
/// Wire protocol: NIP-01 frames.
/// - Client subscribes: `["REQ", <sub_id>, <filter>]`
/// - Server EVENT:      `["EVENT", <sub_id>, <event>]`
/// - Client publish:    `["EVENT", <event>]`
/// - Server OK:         `["OK", <event_id>, <accepted>, <message>]`
public actor NostrWSSClient {
    public struct ConnectionConfig: Sendable {
        public let url: URL
        public let connectTimeout: TimeInterval
        public let ackTimeout: TimeInterval

        public init(
            url: URL,
            connectTimeout: TimeInterval = 8,
            ackTimeout: TimeInterval = 20
        ) {
            self.url = url
            self.connectTimeout = connectTimeout
            self.ackTimeout = ackTimeout
        }
    }

    public enum WSSError: Error, Equatable {
        case connectionTimedOut
        case publishRejected(String)
        case ackTimedOut
        case malformedFrame
        case underlying(String)
    }

    private let config: ConnectionConfig
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var subscriptions: [String: AsyncStream<NostrEvent>.Continuation] = [:]
    private var readerTask: Task<Void, Never>?

    public init(config: ConnectionConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func connect() async throws {
        let task = session.webSocketTask(with: config.url)
        self.task = task
        task.resume()
        readerTask = Task { [weak self] in
            await self?.readerLoop(task: task)
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        readerTask?.cancel()
        for (_, cont) in subscriptions {
            cont.finish()
        }
        subscriptions.removeAll()
    }

    /// Subscribe to events matching `filter` under the supplied id.
    /// The returned `AsyncStream` yields each inbound EVENT frame
    /// targeting this subscription. The caller must `close()` the
    /// stream by cancelling the consuming task when done.
    public func subscribe(
        id: String,
        filter: [String: Any]
    ) async throws -> AsyncStream<NostrEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: NostrEvent.self)
        subscriptions[id] = cont
        let frame = try jsonString(from: ["REQ", id, filter])
        try await send(frame)
        return stream
    }

    /// Publish a fully-signed Nostr event. Returns when the relay
    /// emits an OK frame matching `event.id`, with the accepted bool.
    public func publish(_ event: NostrEvent) async throws {
        let frame = try jsonString(from: ["EVENT", event.toJSON()])
        // Reserve an ack waiter BEFORE sending so the OK that races
        // back can't be dropped.
        let waiter = OkWaiter()
        okWaiters[event.id] = waiter
        defer { okWaiters[event.id] = nil }
        try await send(frame)
        return try await waiter.awaitOk(timeout: config.ackTimeout)
    }

    // MARK: - private

    private var okWaiters: [String: OkWaiter] = [:]

    private func send(_ frame: String) async throws {
        guard let task else { throw WSSError.underlying("not connected") }
        try await task.send(.string(frame))
    }

    private func readerLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
                @unknown default:    continue
                }
                await handleIncoming(text)
            } catch {
                return
            }
        }
    }

    private func handleIncoming(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let arr = raw as? [Any], !arr.isEmpty,
              let kind = arr[0] as? String
        else { return }
        switch kind {
        case "EVENT":
            guard arr.count >= 3,
                  let subId = arr[1] as? String,
                  let evJson = arr[2] as? [String: Any],
                  let event = NostrEvent.fromJSON(evJson)
            else { return }
            subscriptions[subId]?.yield(event)
        case "OK":
            guard arr.count >= 3,
                  let eventId = arr[1] as? String,
                  let accepted = arr[2] as? Bool
            else { return }
            let message = (arr.count >= 4 ? arr[3] as? String : nil) ?? ""
            okWaiters[eventId]?.fulfill(
                accepted: accepted,
                message: message
            )
        case "EOSE", "NOTICE", "CLOSED":
            break
        default:
            break
        }
    }

    private func jsonString(from value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw WSSError.malformedFrame
        }
        return s
    }
}

/// Internal OK-frame waiter. Used by `NostrWSSClient.publish` to
/// suspend until the relay confirms (or rejects) the published
/// event.
private final class OkWaiter: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var fulfilled = false
    private var pendingError: Error?

    func awaitOk(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
            lock.lock()
            if fulfilled {
                lock.unlock()
                if let err = pendingError {
                    cc.resume(throwing: err)
                } else {
                    cc.resume()
                }
            } else {
                continuation = cc
                lock.unlock()
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self.fulfill(accepted: false, message: "ack timeout", isTimeout: true)
                }
            }
        }
    }

    func fulfill(accepted: Bool, message: String, isTimeout: Bool = false) {
        lock.lock()
        if fulfilled {
            lock.unlock()
            return
        }
        fulfilled = true
        let cc = continuation
        continuation = nil
        if accepted {
            pendingError = nil
        } else {
            pendingError = isTimeout
                ? NostrWSSClient.WSSError.ackTimedOut
                : NostrWSSClient.WSSError.publishRejected(message)
        }
        lock.unlock()
        if let cc {
            if let err = pendingError {
                cc.resume(throwing: err)
            } else {
                cc.resume()
            }
        }
    }
}

/// Minimal Nostr event shape used by the claw-share flow.
public struct NostrEvent: Sendable, Equatable {
    public let id: String           // 64-char hex
    public let pubkey: String       // 64-char hex
    public let createdAt: UInt64
    public let kind: UInt32
    public let tags: [[String]]
    public let content: String
    public let sig: String          // 128-char hex

    public init(
        id: String,
        pubkey: String,
        createdAt: UInt64,
        kind: UInt32,
        tags: [[String]],
        content: String,
        sig: String
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "pubkey": pubkey,
            "created_at": createdAt,
            "kind": kind,
            "tags": tags,
            "content": content,
            "sig": sig,
        ]
    }

    static func fromJSON(_ obj: [String: Any]) -> NostrEvent? {
        guard let id = obj["id"] as? String,
              let pubkey = obj["pubkey"] as? String,
              let createdAt = obj["created_at"] as? UInt64
                  ?? (obj["created_at"] as? Int).map(UInt64.init),
              let kind = obj["kind"] as? UInt32
                  ?? (obj["kind"] as? Int).map(UInt32.init),
              let tagsAny = obj["tags"] as? [[String]],
              let content = obj["content"] as? String,
              let sig = obj["sig"] as? String
        else { return nil }
        return NostrEvent(
            id: id, pubkey: pubkey, createdAt: createdAt, kind: kind,
            tags: tagsAny, content: content, sig: sig
        )
    }
}

/// Sign a Nostr event under a Schnorr (BIP-340) keypair. Returns
/// the (id, sig) pair so the caller can build the `NostrEvent`.
/// Mirrors NIP-01 §"Events and signatures".
public enum NostrEventSigning {
    public static func sign(
        privateKey: Data,
        pubkey: String,
        createdAt: UInt64,
        kind: UInt32,
        tags: [[String]],
        content: String
    ) throws -> NostrEvent {
        // Canonical serialization for id: [0, pubkey, created_at, kind, tags, content]
        let payload: [Any] = [0, pubkey, createdAt, kind, tags, content]
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.withoutEscapingSlashes]
        )
        let id = Data(CryptoKit.SHA256.hash(data: payloadData))
        let priv = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        // BIP-340 sign over the precomputed 32-byte id. The
        // auxiliaryRand path takes raw bytes; we pass zeros for a
        // deterministic (test-friendly) signature variant. Production
        // could plug a CSPRNG; the signature is equally valid either
        // way because Schnorr's nonce is derived from `id || aux`.
        var msgBytes = Array(id)
        var aux = [UInt8](repeating: 0, count: 32)
        let sigData = try aux.withUnsafeMutableBytes { auxBuf -> Data in
            let sig = try priv.signature(
                message: &msgBytes,
                auxiliaryRand: auxBuf.baseAddress,
                strict: true
            )
            return sig.dataRepresentation
        }
        return NostrEvent(
            id: id.hexEncodedString(),
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: sigData.hexEncodedString()
        )
    }
}

extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
