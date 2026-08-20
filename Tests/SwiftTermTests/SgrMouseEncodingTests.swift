//
//  SgrMouseEncodingTests.swift
//
//  Pins the SGR (`?1006`) and SGR-Pixels (`?1016`) wire encoding of mouse
//  reports.  The expected bytes were measured against Terminal.app driven by
//  synthesized CGEvents, not read off a specification.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class SwiftTermSgrMouseEncoding {
    private final class RecordingDelegate: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
        var text: String { String(decoding: sent, as: UTF8.self) }
        func reset() { sent.removeAll() }
    }

    private func makeTerminal(_ modes: String = "\u{1b}[?1003h\u{1b}[?1006h") -> (Terminal, RecordingDelegate) {
        let delegate = RecordingDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(byteArray: Array(modes.utf8))
        delegate.reset()
        return (terminal, delegate)
    }

    // MARK: - Hover: no button held

    /// Flags 3 mean "no button".  On a motion report that is a hover, and the
    /// final byte stays `M`: turning it into a release told every application
    /// that button 1 had just been let go, on every pointer move.
    @Test func hoverIsReportedAsNoButtonMotion() {
        let (terminal, delegate) = makeTerminal()
        terminal.sendMotion(buttonFlags: 3, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<35;30;20M")
    }

    /// Measured from Terminal.app for the same gesture: `ESC [ < 51 ; col ; row M`.
    @Test func hoverWithControlMatchesTheReferenceTerminal() {
        let (terminal, delegate) = makeTerminal()
        terminal.sendMotion(buttonFlags: 19, x: 41, y: 11, pixelX: 400, pixelY: 110)
        #expect(delegate.text == "\u{1b}[<51;42;12M")
    }

    @Test func hoverKeepsItsShapeUnderThePixelProtocol() {
        let (terminal, delegate) = makeTerminal("\u{1b}[?1003h\u{1b}[?1016h")
        terminal.sendMotion(buttonFlags: 3, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<35;300;200M")
    }

    // MARK: - What must not change

    @Test func aButtonReleaseIsStillAReleaseReport() {
        let (terminal, delegate) = makeTerminal()
        terminal.sendEvent(buttonFlags: 3, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<0;30;20m")

        delegate.reset()
        terminal.sendEvent(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<16;30;20m")
    }

    @Test func aButtonPressIsUnchanged() {
        let (terminal, delegate) = makeTerminal()
        terminal.sendEvent(buttonFlags: 0, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<0;30;20M")
    }

    @Test func aDragKeepsItsButtonNumber() {
        let (terminal, delegate) = makeTerminal("\u{1b}[?1002h\u{1b}[?1006h")
        terminal.sendMotion(buttonFlags: 0, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<32;30;20M")

        delegate.reset()
        terminal.sendMotion(buttonFlags: 2, x: 30, y: 19, pixelX: 310, pixelY: 200)
        #expect(delegate.text == "\u{1b}[<34;31;20M")
    }

    /// The X10 and urxvt encodings already carried the 3 through; the fix must
    /// not disturb them.  83 = 3 (no button) + 16 (control) + 32 (motion) + 32.
    @Test func theOlderEncodingsAreUntouched() {
        let (terminal, delegate) = makeTerminal("\u{1b}[?1003h")
        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(delegate.sent == [0x1b, 0x5b, 0x4d, 83, UInt8(32 + 30), UInt8(32 + 20)])

        let (urxvt, urxvtDelegate) = makeTerminal("\u{1b}[?1003h\u{1b}[?1015h")
        urxvt.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        #expect(urxvtDelegate.text == "\u{1b}[83;30;20M")
    }
}
#endif
