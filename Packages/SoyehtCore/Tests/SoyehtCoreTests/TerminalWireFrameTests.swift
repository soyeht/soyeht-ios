import Testing
import Foundation
@testable import SoyehtCore

/// Pin the JSON shapes the iOS / macOS clients put on the wire to the
/// server. These bytes match what the server's existing handlers parse,
/// so any drift in field name, ordering, or escape behavior here will
/// silently break PTY attach traffic in production. Any change to these
/// assertions implies a coordinated server-side change.
@Suite struct TerminalWireFrameTests {

    @Test func resizeProducesExpectedJSON() throws {
        let frame = TerminalWireFrame.Resize(cols: 80, rows: 24)
        let text = try TerminalWireFrame.encodedString(frame)
        // Sorted keys: cols before rows before type.
        #expect(text == #"{"cols":80,"rows":24,"type":"resize"}"#)
    }

    @Test func resizeRoundTrips() throws {
        let original = TerminalWireFrame.Resize(cols: 132, rows: 50)
        let text = try TerminalWireFrame.encodedString(original)
        let data = try #require(text.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TerminalWireFrame.Resize.self, from: data)
        #expect(decoded == original)
    }

    @Test func inputProducesExpectedJSON() throws {
        let frame = TerminalWireFrame.Input(data: "ls -la\n")
        let text = try TerminalWireFrame.encodedString(frame)
        #expect(text == #"{"data":"ls -la\n","type":"input"}"#)
    }

    @Test func inputEscapesQuotesAndBackslashes() throws {
        // The previous `"{\"type\":\"input\",\"data\":\"\(text)\"}"` interpolation
        // would corrupt the wire on any user input containing a quote or
        // backslash. `JSONEncoder` escapes both correctly.
        let frame = TerminalWireFrame.Input(data: #"echo "hi\n""#)
        let text = try TerminalWireFrame.encodedString(frame)
        #expect(text == #"{"data":"echo \"hi\\n\"","type":"input"}"#)
    }

    @Test func inputHandlesControlBytes() throws {
        // Ctrl-C lands as 0x03 in the input stream; the encoder must emit
        // a valid `` rather than a raw control byte the server
        // would reject.
        let frame = TerminalWireFrame.Input(data: "\u{0003}")
        let text = try TerminalWireFrame.encodedString(frame)
        let data = try #require(text.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TerminalWireFrame.Input.self, from: data)
        #expect(decoded.data == "\u{0003}")
    }

    @Test func attachHelloProducesExpectedJSON() throws {
        let frame = TerminalWireFrame.AttachHello(
            nonce: "abc123",
            deviceID: "11111111-2222-3333-4444-555555555555",
            paneID: "pane-7"
        )
        let text = try TerminalWireFrame.encodedString(frame)
        // device_id / pane_id snake_case (per server expectation), keys
        // alphabetised by JSONEncoder.
        #expect(text == #"{"device_id":"11111111-2222-3333-4444-555555555555","nonce":"abc123","pane_id":"pane-7","type":"attach_hello"}"#)
    }

    @Test func attachHelloRoundTrips() throws {
        // The wire format is symmetric — what the client sends is what
        // the server parses. Any drift in field names breaks attach.
        let original = TerminalWireFrame.AttachHello(
            nonce: "nonce-1",
            deviceID: "dev-1",
            paneID: "pane-1"
        )
        let text = try TerminalWireFrame.encodedString(original)
        let data = try #require(text.data(using: .utf8))
        let decoded = try JSONDecoder().decode(TerminalWireFrame.AttachHello.self, from: data)
        #expect(decoded == original)
    }
}
