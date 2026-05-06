import Foundation

/// JSON wire shapes for the terminal WebSocket (PTY-attach direction).
///
/// These are the frames the iOS / macOS clients send up to a theyOS server
/// to drive a remote PTY (resize, input) or to complete the attach
/// handshake (`attach_hello`). The server side speaks the same JSON, so
/// any change to a `CodingKeys`, the `type` discriminator, or a field's
/// shape is a wire-protocol change requiring coordinated rollout.
///
/// Hand-rolled `"{\"type\":\"resize\",\"cols\":\(cols),..."` interpolation
/// previously sat at every send site. That pattern has three problems:
///
///   1. Encoding errors are silent: a missing escape on user-supplied input
///      produces invalid JSON the server rejects with no client signal.
///   2. The exact JSON shape is duplicated across iOS and macOS — drift
///      between the two is impossible to catch at compile time.
///   3. Strings cannot be unit-tested for round-trippability.
///
/// Driving every send through `JSONEncoder` + `Codable` collapses the
/// surface to one place, makes the wire shape testable, and makes encode
/// failures throw instead of disappear.
public enum TerminalWireFrame {

    /// `{"type":"resize","cols":N,"rows":N}` — server side resizes the PTY
    /// to the given dimensions. Both axes are bounded by
    /// `PairingPayloadLimits.columnRange` / `rowRange` on the receive side.
    public struct Resize: Codable, Equatable, Sendable {
        public let type: String
        public let cols: Int
        public let rows: Int

        public init(cols: Int, rows: Int) {
            self.type = "resize"
            self.cols = cols
            self.rows = rows
        }
    }

    /// `{"type":"input","data":"…"}` — server side writes `data` into the
    /// PTY master fd. `data` is a UTF-8 string and may include arbitrary
    /// bytes (terminal control sequences, paste payloads, etc.); the
    /// `Codable` encoder is responsible for escaping it correctly.
    public struct Input: Codable, Equatable, Sendable {
        public let type: String
        public let data: String

        public init(data: String) {
            self.type = "input"
            self.data = data
        }
    }

    /// `{"type":"attach_hello","nonce":"…","device_id":"…","pane_id":"…"}`
    /// — phase-2 handshake that binds a paired device to a specific
    /// presence-issued pane nonce.
    public struct AttachHello: Codable, Equatable, Sendable {
        public let type: String
        public let nonce: String
        public let deviceID: String
        public let paneID: String

        public init(nonce: String, deviceID: String, paneID: String) {
            self.type = "attach_hello"
            self.nonce = nonce
            self.deviceID = deviceID
            self.paneID = paneID
        }

        // Server-side keys are snake_case; map explicitly so the wire
        // shape does not depend on JSONEncoder's default key strategy.
        private enum CodingKeys: String, CodingKey {
            case type
            case nonce
            case deviceID = "device_id"
            case paneID = "pane_id"
        }
    }

    /// Single shared encoder. `JSONEncoder` is documented thread-safe for
    /// configuration-after-init scenarios, and we use the default
    /// settings (no pretty print, no key escape changes) so the wire bytes
    /// stay tight.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Stable key order for cleaner test assertions and identical
        // diffs across builds. Negligible cost for the small frames we
        // send and the server tolerates either order.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Encode any frame to its wire-string form.
    ///
    /// Throws when the frame contains data that cannot be JSON-encoded
    /// (e.g. a `Float.infinity`); callers receive a real error instead of
    /// the previous `try?` silently dropping the frame.
    public static func encodedString<Frame: Encodable>(_ frame: Frame) throws -> String {
        let data = try encoder.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            // `JSONEncoder` always produces valid UTF-8, so reaching this
            // branch implies a corrupted runtime — surface it loudly
            // rather than fall through.
            throw EncodingError.invalidValue(
                frame,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "JSONEncoder produced non-UTF-8 output"
                )
            )
        }
        return text
    }
}
