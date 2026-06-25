import CryptoKit
import Foundation
import P256K

public actor NostrWSSClient {
    public enum WSSError: Error, Equatable {
        case publishRejected(String)
        case ackTimedOut
        case malformedFrame
    }

    private let transport: any NostrWireTransport
    private let ackTimeout: TimeInterval
    private var subscriptions: [String: AsyncStream<NostrEvent>.Continuation] = [:]
    private var okWaiters: [String: OkWaiter] = [:]
    private var readerTask: Task<Void, Never>?

    public init(transport: any NostrWireTransport, ackTimeout: TimeInterval = 20) {
        self.transport = transport
        self.ackTimeout = ackTimeout
    }

    public func connect() async throws {
        if let urlTransport = transport as? URLSessionWebSocketTransport {
            await urlTransport.connect()
        }
        let weakSelf = WeakSelf(value: self)
        readerTask = Task { [weakSelf] in
            await weakSelf.value?.readerLoop()
        }
    }

    public func close() async {
        await transport.close()
        readerTask?.cancel()
        for continuation in subscriptions.values {
            continuation.finish()
        }
        subscriptions.removeAll()
        for waiter in okWaiters.values {
            waiter.fulfill(accepted: false, message: "client closed")
        }
        okWaiters.removeAll()
    }

    public func subscribe(id: String, filter: [String: Any]) async throws -> AsyncStream<NostrEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: NostrEvent.self)
        subscriptions[id] = continuation
        try await transport.send(try jsonString(from: ["REQ", id, filter]))
        return stream
    }

    public func publish(_ event: NostrEvent) async throws {
        let waiter = OkWaiter()
        okWaiters[event.id] = waiter
        defer { okWaiters.removeValue(forKey: event.id) }
        try await transport.send(try jsonString(from: ["EVENT", event.toJSON()]))
        try await waiter.awaitOk(timeout: ackTimeout)
    }

    private func readerLoop() async {
        while !Task.isCancelled {
            guard let text = try? await transport.recv() else { return }
            await handleIncoming(text)
        }
    }

    private func handleIncoming(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [Any],
              let kind = array.first as? String
        else {
            return
        }
        switch kind {
        case "EVENT":
            guard array.count >= 3,
                  let subId = array[1] as? String,
                  let eventJSON = array[2] as? [String: Any],
                  let event = NostrEvent.fromJSON(eventJSON)
            else {
                return
            }
            subscriptions[subId]?.yield(event)
        case "OK":
            guard array.count >= 3,
                  let eventId = array[1] as? String,
                  let accepted = array[2] as? Bool
            else {
                return
            }
            let message = (array.count >= 4 ? array[3] as? String : nil) ?? ""
            okWaiters[eventId]?.fulfill(accepted: accepted, message: message)
        default:
            break
        }
    }

    private func jsonString(from value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WSSError.malformedFrame
        }
        return string
    }
}

private final class WeakSelf<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(value: T) {
        self.value = value
    }
}

private final class OkWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var fulfilled = false
    private var pendingError: Error?

    func awaitOk(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if fulfilled {
                let error = pendingError
                lock.unlock()
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fulfill(accepted: false, message: "ack timeout", isTimeout: true)
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
        let continuation = continuation
        self.continuation = nil
        pendingError = accepted ? nil : (isTimeout ? NostrWSSClient.WSSError.ackTimedOut : NostrWSSClient.WSSError.publishRejected(message))
        let error = pendingError
        lock.unlock()

        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

public struct NostrEvent: Sendable, Equatable {
    public let id: String
    public let pubkey: String
    public let createdAt: UInt64
    public let kind: UInt32
    public let tags: [[String]]
    public let content: String
    public let sig: String

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

    static func fromJSON(_ object: [String: Any]) -> NostrEvent? {
        guard let id = object["id"] as? String,
              let pubkey = object["pubkey"] as? String,
              let createdAt = object["created_at"] as? UInt64 ?? (object["created_at"] as? Int).map(UInt64.init),
              let kind = object["kind"] as? UInt32 ?? (object["kind"] as? Int).map(UInt32.init),
              let tags = object["tags"] as? [[String]],
              let content = object["content"] as? String,
              let sig = object["sig"] as? String
        else {
            return nil
        }
        return NostrEvent(
            id: id,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: sig
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
        let privateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        var message = Array(id)
        var auxiliaryRandomness = [UInt8](repeating: 0, count: 32)
        let signature = try auxiliaryRandomness.withUnsafeMutableBytes { buffer -> Data in
            let signature = try privateKey.signature(
                message: &message,
                auxiliaryRand: buffer.baseAddress,
                strict: true
            )
            return signature.dataRepresentation
        }
        return NostrEvent(
            id: id.soyehtHexEncodedString(),
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: signature.soyehtHexEncodedString()
        )
    }
}
