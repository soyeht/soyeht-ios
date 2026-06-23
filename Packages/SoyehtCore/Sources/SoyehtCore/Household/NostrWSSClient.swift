import Foundation
import CryptoKit
import P256K

/// NIP-01 Nostr client. Frame handling (REQ/EVENT/OK/EOSE/NOTICE)
/// lives here; the byte transport is pluggable via
/// `NostrWireTransport` so tests inject an in-process mock relay
/// while production uses URLSessionWebSocketTask.
///
/// NIP-01 frames:
/// - Client subscribe: `["REQ", <sub_id>, <filter>]`
/// - Server event:     `["EVENT", <sub_id>, <event>]`
/// - Client publish:   `["EVENT", <event>]`
/// - Server OK:        `["OK", <event_id>, <accepted>, <message>]`
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

    private let transport: any NostrWireTransport
    private let ackTimeout: TimeInterval
    private var subscriptions: [String: AsyncStream<NostrEvent>.Continuation] = [:]
    private var okWaiters: [String: OkWaiter] = [:]
    private var readerTask: Task<Void, Never>?

    public init(
        transport: any NostrWireTransport,
        ackTimeout: TimeInterval = 20
    ) {
        self.transport = transport
        self.ackTimeout = ackTimeout
    }

    /// Convenience init for production: wraps URLSessionWebSocketTask.
    public init(config: ConnectionConfig, session: URLSession = .shared) {
        self.transport = URLSessionWebSocketTransport(url: config.url, session: session)
        self.ackTimeout = config.ackTimeout
    }

    public func connect() async throws {
        if let urlTransport = transport as? URLSessionWebSocketTransport {
            await urlTransport.connect()
        }
        // In-process transport is "always connected" — no setup needed.
        let weakSelf = WeakSelf(value: self)
        readerTask = Task { [weakSelf] in
            await weakSelf.value?.readerLoop()
        }
    }

    public func close() async {
        await transport.close()
        readerTask?.cancel()
        for (_, cont) in subscriptions {
            cont.finish()
        }
        subscriptions.removeAll()
        for (_, waiter) in okWaiters {
            waiter.fulfill(accepted: false, message: "client closed")
        }
        okWaiters.removeAll()
    }

    public func subscribe(
        id: String,
        filter: [String: Any]
    ) async throws -> AsyncStream<NostrEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: NostrEvent.self)
        subscriptions[id] = cont
        let frame = try jsonString(from: ["REQ", id, filter])
        try await transport.send(frame)
        return stream
    }

    public func publish(_ event: NostrEvent) async throws {
        let frame = try jsonString(from: ["EVENT", event.toJSON()])
        let waiter = OkWaiter()
        okWaiters[event.id] = waiter
        defer { okWaiters.removeValue(forKey: event.id) }
        try await transport.send(frame)
        try await waiter.awaitOk(timeout: ackTimeout)
    }

    // MARK: - private

    private func readerLoop() async {
        while !Task.isCancelled {
            do {
                guard let text = try await transport.recv() else { return }
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
            okWaiters[eventId]?.fulfill(accepted: accepted, message: message)
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

// Workaround: Task closures can't capture `self` weakly directly
// from inside an actor's initializer/method without a wrapper.
private final class WeakSelf<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(value: T) { self.value = value }
}

/// OK-frame waiter used by `NostrWSSClient.publish`.
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
    public let id: String
    public let pubkey: String
    public let createdAt: UInt64
    public let kind: UInt32
    public let tags: [[String]]
    public let content: String
    public let sig: String

    public init(
        id: String, pubkey: String, createdAt: UInt64, kind: UInt32,
        tags: [[String]], content: String, sig: String
    ) {
        self.id = id; self.pubkey = pubkey; self.createdAt = createdAt
        self.kind = kind; self.tags = tags; self.content = content; self.sig = sig
    }

    func toJSON() -> [String: Any] {
        ["id": id, "pubkey": pubkey, "created_at": createdAt,
         "kind": kind, "tags": tags, "content": content, "sig": sig]
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

public enum NostrEventSigning {
    public static func sign(
        privateKey: Data,
        pubkey: String,
        createdAt: UInt64,
        kind: UInt32,
        tags: [[String]],
        content: String
    ) throws -> NostrEvent {
        let payload: [Any] = [0, pubkey, createdAt, kind, tags, content]
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.withoutEscapingSlashes]
        )
        let id = Data(CryptoKit.SHA256.hash(data: payloadData))
        let priv = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
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
