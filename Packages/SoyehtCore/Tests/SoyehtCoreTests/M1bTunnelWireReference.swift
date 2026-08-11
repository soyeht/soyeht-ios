import Foundation

// M1b (docs/mesh-plan.md, theyos) requires Rust↔Swift wire vectors that are
// byte-identical for framing and frame bodies. This is the Swift half of that
// conformance surface: an independent reimplementation of theyos
// `tunnel-wire-rs/src/tunnel_wire.rs` (`TunnelFrame`) and
// `tunnel-wire-rs/src/frame_stream.rs` (4-byte big-endian length prefix).
//
// It lives in the test target on purpose — the M1a precedent: conformance
// harnesses stay isolated from the production build until a milestone (M4)
// needs the surface in production, at which point these vectors become that
// layer's acceptance tests. Production data-plane traffic today crosses the
// wire exclusively inside the Rust FFI (`RelayStreamGuestFFI`), so nothing
// here is reachable from shipping code.
//
// Two decoder asymmetries below are deliberate mirrors of the Rust decoder,
// not bugs: tag-only frames ignore trailing payload bytes, and `.exit(.lost)`
// ignores its four value bytes. Re-encoding such a decoded frame therefore
// does not reproduce the input bytes; the vectors pin both behaviors so a
// future "cleanup" on either side becomes a visible contract break.

enum M1bWireDecodeError: Error, Equatable {
    case emptyFrame
    case unknownFrameKind(UInt8)
    case badWindowFrame
    case badResizeFrame
    case badExitFrame
    case unknownExitTag(UInt8)
    case zeroLengthPrefix
    case oversizedLengthPrefix(UInt32)
    case oversizedFrameBody(Int)
    case truncatedStream
}

enum M1bTargetExitReference: Equatable {
    case code(Int32)
    case signal(Int32)
    case lost

    static let tagCode: UInt8 = 0x01
    static let tagSignal: UInt8 = 0x02
    static let tagLost: UInt8 = 0x03

    func encode() -> Data {
        let (tag, value): (UInt8, Int32)
        switch self {
        case .code(let code): (tag, value) = (Self.tagCode, code)
        case .signal(let signal): (tag, value) = (Self.tagSignal, signal)
        case .lost: (tag, value) = (Self.tagLost, 0)
        }
        var out = Data([tag])
        out.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
        return out
    }

    static func decode(_ payload: Data) throws -> M1bTargetExitReference {
        guard payload.count == 5 else {
            throw M1bWireDecodeError.badExitFrame
        }
        let bytes = [UInt8](payload)
        let value = Int32(bitPattern: UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 8 | UInt32(bytes[4]))
        switch bytes[0] {
        case tagCode: return .code(value)
        case tagSignal: return .signal(value)
        case tagLost: return .lost
        case let other: throw M1bWireDecodeError.unknownExitTag(other)
        }
    }
}

enum M1bTunnelWireFrame: Equatable {
    case health(Data)
    case open
    case openPersistent
    case data(Data)
    case close
    case error(String)
    case window(UInt32)
    case resize(cols: UInt16, rows: UInt16)
    case exit(M1bTargetExitReference)
    case networkSettings(Data)

    static let frameHealth: UInt8 = 0x01
    static let frameOpen: UInt8 = 0x10
    static let frameData: UInt8 = 0x11
    static let frameClose: UInt8 = 0x12
    static let frameError: UInt8 = 0x13
    static let frameWindow: UInt8 = 0x14
    static let frameResize: UInt8 = 0x15
    static let frameExit: UInt8 = 0x16
    static let frameNetworkSettings: UInt8 = 0x17
    static let frameOpenPersistent: UInt8 = 0x18

    static let maxFrameLength = 64 * 1024

    func encode() -> Data {
        var out = Data()
        switch self {
        case .health(let payload):
            out.append(Self.frameHealth)
            out.append(payload)
        case .open:
            out.append(Self.frameOpen)
        case .openPersistent:
            out.append(Self.frameOpenPersistent)
        case .data(let payload):
            out.append(Self.frameData)
            out.append(payload)
        case .close:
            out.append(Self.frameClose)
        case .error(let reason):
            out.append(Self.frameError)
            out.append(Data(reason.utf8))
        case .window(let credit):
            out.append(Self.frameWindow)
            out.append(contentsOf: withUnsafeBytes(of: credit.bigEndian, Array.init))
        case .resize(let cols, let rows):
            out.append(Self.frameResize)
            out.append(contentsOf: withUnsafeBytes(of: cols.bigEndian, Array.init))
            out.append(contentsOf: withUnsafeBytes(of: rows.bigEndian, Array.init))
        case .exit(let status):
            out.append(Self.frameExit)
            out.append(status.encode())
        case .networkSettings(let body):
            out.append(Self.frameNetworkSettings)
            out.append(body)
        }
        return out
    }

    static func decode(_ bytes: Data) throws -> M1bTunnelWireFrame {
        guard let kind = bytes.first else {
            throw M1bWireDecodeError.emptyFrame
        }
        let payload = bytes.dropFirst()
        switch kind {
        case frameHealth:
            return .health(Data(payload))
        case frameOpen:
            return .open
        case frameOpenPersistent:
            return .openPersistent
        case frameData:
            return .data(Data(payload))
        case frameClose:
            return .close
        case frameError:
            // Rust uses `String::from_utf8_lossy`; `String(decoding:as:)`
            // applies the same Unicode maximal-subpart U+FFFD substitution.
            return .error(String(decoding: payload, as: UTF8.self))
        case frameWindow:
            guard payload.count == 4 else {
                throw M1bWireDecodeError.badWindowFrame
            }
            let bytes = [UInt8](payload)
            return .window(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case frameResize:
            guard payload.count == 4 else {
                throw M1bWireDecodeError.badResizeFrame
            }
            let bytes = [UInt8](payload)
            return .resize(
                cols: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                rows: UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            )
        case frameExit:
            return .exit(try M1bTargetExitReference.decode(Data(payload)))
        case frameNetworkSettings:
            return .networkSettings(Data(payload))
        case let other:
            throw M1bWireDecodeError.unknownFrameKind(other)
        }
    }
}

enum M1bLengthPrefixedFraming {
    /// One frame as it crosses the stream: 4-byte big-endian length, then the
    /// encoded frame body. Mirrors the WRITER's acceptance rule too — Rust's
    /// `NonblockingFrameWriter::enqueue` refuses a body over `MAX_FRAME_LEN`
    /// (total encoded frame, tag included), so an oversized Data payload
    /// fails here instead of producing a frame every reader must reject.
    static func encode(_ frame: M1bTunnelWireFrame) throws -> Data {
        let body = frame.encode()
        guard body.count <= M1bTunnelWireFrame.maxFrameLength else {
            throw M1bWireDecodeError.oversizedFrameBody(body.count)
        }
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        out.append(body)
        return out
    }

    /// Decode a byte stream into consecutive frames with the Rust reader's
    /// exact acceptance rules: declared length must be nonzero and at most
    /// `maxFrameLength`, and the stream must end exactly on a frame boundary.
    static func decodeStream(_ data: Data) throws -> [M1bTunnelWireFrame] {
        var frames: [M1bTunnelWireFrame] = []
        var index = data.startIndex
        while index != data.endIndex {
            guard data.distance(from: index, to: data.endIndex) >= 4 else {
                throw M1bWireDecodeError.truncatedStream
            }
            let prefixEnd = data.index(index, offsetBy: 4)
            let bytes = [UInt8](data[index..<prefixEnd])
            let length = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            guard length != 0 else {
                throw M1bWireDecodeError.zeroLengthPrefix
            }
            guard Int(length) <= M1bTunnelWireFrame.maxFrameLength else {
                throw M1bWireDecodeError.oversizedLengthPrefix(length)
            }
            guard data.distance(from: prefixEnd, to: data.endIndex) >= Int(length) else {
                throw M1bWireDecodeError.truncatedStream
            }
            let bodyEnd = data.index(prefixEnd, offsetBy: Int(length))
            frames.append(try M1bTunnelWireFrame.decode(Data(data[prefixEnd..<bodyEnd])))
            index = bodyEnd
        }
        return frames
    }
}
