import Testing
import Foundation
@testable import SoyehtCore

@Suite struct TerminalProtocolCodecTests {

    // MARK: - decodeControlFrame

    @Test("Decodes a well-formed control frame")
    func decodesControlFrame() {
        var bytes: [UInt8] = [0x00, 0x01]
        bytes.append(contentsOf: Array("CTL:replay_done".utf8))
        let data = Data(bytes)
        #expect(TerminalProtocolCodec.decodeControlFrame(data) == "replay_done")
    }

    @Test("Decodes a control frame with arguments")
    func decodesControlFrameWithArguments() {
        var bytes: [UInt8] = [0x00, 0x01]
        bytes.append(contentsOf: Array("CTL:subscriber_lagged:42".utf8))
        let data = Data(bytes)
        #expect(TerminalProtocolCodec.decodeControlFrame(data) == "subscriber_lagged:42")
    }

    @Test("Returns nil for binary terminal output without the CTL prefix")
    func ignoresPlainBinaryFrame() {
        let data = Data([0x1B, 0x5B, 0x32, 0x4A]) // ESC [ 2 J — clear screen
        #expect(TerminalProtocolCodec.decodeControlFrame(data) == nil)
    }

    @Test("Returns nil when the frame is too short to carry CTL content")
    func ignoresTooShortFrame() {
        // Magic + "CTL:" is exactly 6 bytes; need at least one content byte.
        var bytes: [UInt8] = [0x00, 0x01]
        bytes.append(contentsOf: Array("CTL:".utf8))
        #expect(TerminalProtocolCodec.decodeControlFrame(Data(bytes)) == nil)
    }

    @Test("Returns nil when only the magic bytes are present")
    func ignoresMagicOnly() {
        let data = Data([0x00, 0x01])
        #expect(TerminalProtocolCodec.decodeControlFrame(data) == nil)
    }

    // MARK: - controlMarkerName

    @Test("Extracts marker name before the first colon")
    func extractsMarkerName() {
        #expect(TerminalProtocolCodec.controlMarkerName(from: "session_ended") == "session_ended")
        #expect(TerminalProtocolCodec.controlMarkerName(from: "subscriber_lagged:42") == "subscriber_lagged")
        #expect(TerminalProtocolCodec.controlMarkerName(from: "") == "")
    }

    // MARK: - sanitizeProtocolText

    @Test("Returns nil for bare protocol tokens")
    func suppressesBareTokens() {
        #expect(TerminalProtocolCodec.sanitizeProtocolText("guide") == nil)
        #expect(TerminalProtocolCodec.sanitizeProtocolText("resync_done") == nil)
        #expect(TerminalProtocolCodec.sanitizeProtocolText("resync-docs") == nil)
        #expect(TerminalProtocolCodec.sanitizeProtocolText("snapshot_done") == nil)
        #expect(TerminalProtocolCodec.sanitizeProtocolText("snapshot_start") == nil)
    }

    @Test("Returns nil for resync/snapshot prefixed tokens")
    func suppressesPrefixedTokens() {
        #expect(TerminalProtocolCodec.sanitizeProtocolText("resync_x") == nil)
        #expect(TerminalProtocolCodec.sanitizeProtocolText("resync-anything") == nil)
        #expect(TerminalProtocolCodec.sanitizeProtocolText("snapshot_foo") == nil)
    }

    @Test("Strips embedded protocol lines and keeps the rest")
    func stripsEmbeddedTokens() {
        let raw = "hello\nresync_done\nworld\n"
        let cleaned = TerminalProtocolCodec.sanitizeProtocolText(raw)
        #expect(cleaned?.contains("resync_done") == false)
        #expect(cleaned?.contains("hello") == true)
        #expect(cleaned?.contains("world") == true)
    }

    @Test("Returns the original text when it is not a protocol candidate")
    func passesThroughOrdinaryText() {
        #expect(TerminalProtocolCodec.sanitizeProtocolText("hello world") == "hello world")
    }

    @Test("Returns the original whitespace-only text unchanged")
    func passesThroughEmptyAndWhitespace() {
        #expect(TerminalProtocolCodec.sanitizeProtocolText("") == "")
        #expect(TerminalProtocolCodec.sanitizeProtocolText("   ") == "   ")
    }

    @Test("Does not strip user content that merely mentions a token mid-line")
    func doesNotStripTokenMidLine() {
        // The regex anchors with `^...$` (multiline) — `cat resync_done.log`
        // should survive untouched.
        let raw = "cat resync_done.log"
        #expect(TerminalProtocolCodec.sanitizeProtocolText(raw) == raw)
    }

    // MARK: - shouldSuppressProtocolText

    @Test("shouldSuppressProtocolText covers the same tokens as sanitize")
    func shouldSuppressMirrorsSanitize() {
        #expect(TerminalProtocolCodec.shouldSuppressProtocolText("guide"))
        #expect(TerminalProtocolCodec.shouldSuppressProtocolText("resync_done"))
        #expect(TerminalProtocolCodec.shouldSuppressProtocolText("snapshot_anything"))
        #expect(TerminalProtocolCodec.shouldSuppressProtocolText("hello") == false)
        #expect(TerminalProtocolCodec.shouldSuppressProtocolText("") == false)
    }
}
