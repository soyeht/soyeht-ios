import Foundation

/// Offset-bearing local PTY protocol v1. VM and legacy terminal streams do
/// not use this codec. Control JSON is never interpreted as terminal output.
public enum LocalTerminalStream {
    public static var retainedHistoryGapMessage: String {
        String(localized: "terminal.history.removed", defaultValue: "Earlier terminal output is no longer available.", bundle: .module)
    }
    public static let version = 1
    public static let outputPrefix = Data([0, 2, 80, 84, 89, 58])

    public enum Failure: Error, Equatable, Sendable {
        case malformedFrame
        case instanceMismatch
        case discontinuity(expected: UInt64, actual: UInt64)
        case cursorOverflow
    }

    public enum Event: Equatable, Sendable {
        case attached(instanceID: String, baseOffset: UInt64, replayEnd: UInt64)
        case data(offset: UInt64, bytes: Data)
        case gap(from: UInt64, to: UInt64)
        case replayEnd(offset: UInt64)
        case resyncRequired(baseOffset: UInt64, endOffset: UInt64)
        case exited(instanceID: String, finalOffset: UInt64, exitCode: Int32?, reason: String)
        case error(code: String)
    }

    public static func decodeOutput(_ data: Data) throws -> Event {
        let header = outputPrefix.count + 8
        guard data.count >= header, data.starts(with: outputPrefix) else {
            throw Failure.malformedFrame
        }
        let offset = data.dropFirst(outputPrefix.count).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let bytes = Data(data.dropFirst(header))
        guard !offset.addingReportingOverflow(UInt64(bytes.count)).overflow else { throw Failure.cursorOverflow }
        return .data(offset: offset, bytes: bytes)
    }

    private struct Control: Decodable {
        struct Info: Decodable { let session_instance_id: String }
        let type: String
        let info: Info?
        let base_offset: UInt64?
        let replay_end: UInt64?
        let end_offset: UInt64?
        let offset: UInt64?
        let from: UInt64?
        let to: UInt64?
        let session_instance_id: String?
        let final_offset: UInt64?
        let exit_code: Int32?
        let reason: String?
        let code: String?
    }

    public static func decodeControl(_ text: String) throws -> Event {
        let message = try JSONDecoder().decode(Control.self, from: Data(text.utf8))
        switch message.type {
        case "attached":
            guard let id = message.info?.session_instance_id, UUID(uuidString: id) != nil,
                  let base = message.base_offset, let end = message.replay_end, base <= end else { throw Failure.malformedFrame }
            return .attached(instanceID: id, baseOffset: base, replayEnd: end)
        case "gap":
            guard let from = message.from, let to = message.to, from < to else { throw Failure.malformedFrame }
            return .gap(from: from, to: to)
        case "replay_end":
            guard let offset = message.offset else { throw Failure.malformedFrame }
            return .replayEnd(offset: offset)
        case "resync_required":
            guard let base = message.base_offset, let end = message.end_offset, base <= end else { throw Failure.malformedFrame }
            return .resyncRequired(baseOffset: base, endOffset: end)
        case "exit":
            guard let id = message.session_instance_id, UUID(uuidString: id) != nil,
                  let offset = message.final_offset, let reason = message.reason else { throw Failure.malformedFrame }
            return .exited(instanceID: id, finalOffset: offset, exitCode: message.exit_code, reason: reason)
        case "error":
            guard let code = message.code else { throw Failure.malformedFrame }
            return .error(code: code)
        default: throw Failure.malformedFrame
        }
    }
}

/// The receiver and renderer have different cursors. Only committed bytes
/// may be omitted on reconnect. Keep this value with the terminal emulator;
/// a newly constructed emulator starts from zero even for the same session.
public struct LocalTerminalReplayCursor: Equatable, Sendable {
    public let instanceID: String
    public private(set) var applied: UInt64 = 0
    public private(set) var received: UInt64 = 0

    public init(instanceID: String) { self.instanceID = instanceID }

    public mutating func discardUnapplied() { received = applied }

    public func validate(instanceID: String) throws {
        guard self.instanceID == instanceID else { throw LocalTerminalStream.Failure.instanceMismatch }
    }

    /// Returns only bytes not already queued on this transport. A forward
    /// jump requires a separate GAP event; it can never become a silent seek.
    public mutating func receive(offset: UInt64, bytes: Data) throws -> (offset: UInt64, bytes: Data) {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes.count))
        guard !overflow else { throw LocalTerminalStream.Failure.cursorOverflow }
        guard offset <= received else { throw LocalTerminalStream.Failure.discontinuity(expected: received, actual: offset) }
        if end <= received { return (received, Data()) }
        let skipped = Int(received - offset)
        let result = (received, Data(bytes.dropFirst(skipped)))
        received = end
        return result
    }

    public mutating func receiveGap(from: UInt64, to: UInt64) throws {
        guard from == received, to > from else { throw LocalTerminalStream.Failure.discontinuity(expected: received, actual: from) }
        received = to
    }

    public mutating func commit(offset: UInt64, byteCount: Int) throws {
        guard byteCount >= 0 else { throw LocalTerminalStream.Failure.malformedFrame }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(byteCount))
        guard !overflow else { throw LocalTerminalStream.Failure.cursorOverflow }
        guard offset == applied, end <= received else { throw LocalTerminalStream.Failure.discontinuity(expected: applied, actual: offset) }
        applied = end
    }

    public mutating func commitGap(from: UInt64, to: UInt64) throws {
        guard from == applied, to > from, to <= received else { throw LocalTerminalStream.Failure.discontinuity(expected: applied, actual: from) }
        applied = to
    }
}
