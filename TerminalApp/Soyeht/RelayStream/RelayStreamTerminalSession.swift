import Foundation
import RelayStreamGuestFFI

enum RelayStreamTerminalFrame: Sendable, Equatable {
    case data(Data)
    case window(Int64)
    case exitCode(Int64)
    case exitSignal(String)
    case exitLost
    case close
    case error(String)
    case health(Data)
    case open
}

protocol RelayStreamTerminalSession: Sendable {
    func send(data: Data) async throws
    func resize(cols: UInt16, rows: UInt16) async throws
    func close() async throws
    func nextFrame() async throws -> RelayStreamTerminalFrame
}

struct RelayStreamTerminalConfiguration: Sendable {
    let id: UUID
    let title: String
    let session: any RelayStreamTerminalSession

    init(id: UUID = UUID(), title: String, session: any RelayStreamTerminalSession) {
        self.id = id
        self.title = title
        self.session = session
    }
}

struct RelayStreamGuestDataPlaneTerminalSession: RelayStreamTerminalSession {
    let session: RelayStreamGuestDataPlaneSession

    func send(data: Data) async throws {
        try await session.send(data: data)
    }

    func resize(cols: UInt16, rows: UInt16) async throws {
        try await session.resize(cols: cols, rows: rows)
    }

    func close() async throws {
        try await session.close()
    }

    func nextFrame() async throws -> RelayStreamTerminalFrame {
        let frame = try await session.nextFrame()
        return Self.map(frame)
    }

    static func map(_ frame: RelayStreamGuestFrameRecord) -> RelayStreamTerminalFrame {
        switch frame.kind {
        case .data:
            return .data(frame.data)
        case .window:
            return .window(frame.number)
        case .exitCode:
            return .exitCode(frame.number)
        case .exitSignal:
            return .exitSignal(frame.text)
        case .exitLost:
            return .exitLost
        case .close:
            return .close
        case .error:
            return .error(frame.text)
        case .health:
            return .health(frame.data)
        case .open:
            return .open
        }
    }
}
