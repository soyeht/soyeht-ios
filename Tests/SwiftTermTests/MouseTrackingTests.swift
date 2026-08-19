//
//  MouseTrackingTests.swift
//
//  Regression coverage for the mouse-report stream the terminal sends to the
//  child process.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class SwiftTermMouseTracking {
    /// Records everything the terminal writes back to the child process.
    private final class RecordingDelegate: TerminalDelegate {
        var sent: [UInt8] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }

        var text: String { String(decoding: sent, as: UTF8.self) }

        func reset() { sent.removeAll() }
    }

    private func makeTerminal() -> (Terminal, RecordingDelegate) {
        let delegate = RecordingDelegate()
        let terminal = Terminal(delegate: delegate)
        return (terminal, delegate)
    }

    private func feed(_ terminal: Terminal, _ text: String) {
        terminal.feed(byteArray: Array(text.utf8))
    }

    /// `CSI ? 1003 h` (any-event tracking) + `CSI ? 1006 h` (SGR encoding): what
    /// opencode, htop and most Bubble Tea/OpenTUI applications turn on.
    private func enableAnyEventSgr(_ terminal: Terminal) {
        feed(terminal, "\u{1b}[?1003h\u{1b}[?1006h")
    }

    // MARK: - Motion is reported per cell, not per host event

    @Test func motionInsideTheSameCellIsReportedOnce() {
        let (terminal, delegate) = makeTerminal()
        enableAnyEventSgr(terminal)
        delegate.reset()

        // Three host motion events landing on the same character cell: the
        // pointer never crossed a cell boundary, so the child hears about it once.
        // Button flags 19 = no button (3) + control (16), i.e. what the pointer
        // reports while the user is holding Ctrl to press Ctrl+C.
        for _ in 0 ..< 3 {
            terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        }

        // One report, and it is the `ESC [ < 48 ; 30 ; 20 m` whose tail bash
        // echoes as `48;30;20m` when it lands on the prompt after the
        // application that asked for tracking is already gone.
        #expect(delegate.text == "\u{1b}[<48;30;20m")
    }

    @Test func motionIntoADifferentCellIsReported() {
        let (terminal, delegate) = makeTerminal()
        enableAnyEventSgr(terminal)
        delegate.reset()

        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 305, pixelY: 201)
        terminal.sendMotion(buttonFlags: 19, x: 30, y: 19, pixelX: 310, pixelY: 201)

        #expect(delegate.text == "\u{1b}[<48;30;20m\u{1b}[<48;31;20m")
    }

    @Test func buttonEventsAreNeverSuppressed() {
        let (terminal, delegate) = makeTerminal()
        enableAnyEventSgr(terminal)
        delegate.reset()

        // Press, release and press again without moving: all three must reach
        // the application, otherwise double clicks would be swallowed.
        terminal.sendEvent(buttonFlags: 0, x: 29, y: 19, pixelX: 300, pixelY: 200)
        terminal.sendEvent(buttonFlags: 3, x: 29, y: 19, pixelX: 300, pixelY: 200)
        terminal.sendEvent(buttonFlags: 0, x: 29, y: 19, pixelX: 300, pixelY: 200)

        #expect(delegate.text == "\u{1b}[<0;30;20M\u{1b}[<0;30;20m\u{1b}[<0;30;20M")
    }

    @Test func motionAfterAButtonEventInTheSameCellIsSuppressed() {
        let (terminal, delegate) = makeTerminal()
        feed(terminal, "\u{1b}[?1002h\u{1b}[?1006h")
        delegate.reset()

        terminal.sendEvent(buttonFlags: 0, x: 29, y: 19, pixelX: 300, pixelY: 200)
        terminal.sendMotion(buttonFlags: 0, x: 29, y: 19, pixelX: 301, pixelY: 200)
        terminal.sendMotion(buttonFlags: 0, x: 29, y: 20, pixelX: 301, pixelY: 220)

        #expect(delegate.text == "\u{1b}[<0;30;20M\u{1b}[<32;30;21M")
    }

    @Test func sgrPixelProtocolComparesPixelsNotCells() {
        let (terminal, delegate) = makeTerminal()
        // `CSI ? 1016 h` asks for pixel resolution, so a move inside one cell is
        // still information the application asked for.
        feed(terminal, "\u{1b}[?1003h\u{1b}[?1016h")
        delegate.reset()

        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)
        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 302, pixelY: 200)

        #expect(delegate.text == "\u{1b}[<48;300;200m\u{1b}[<48;302;200m")
    }

    @Test func enablingTrackingAgainReportsTheFirstMotion() {
        let (terminal, delegate) = makeTerminal()
        enableAnyEventSgr(terminal)
        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)

        // Application quits, a new one starts and turns tracking on again: it has
        // never been told where the pointer is, so the next motion must report.
        feed(terminal, "\u{1b}[?1003l")
        enableAnyEventSgr(terminal)
        delegate.reset()

        terminal.sendMotion(buttonFlags: 19, x: 29, y: 19, pixelX: 300, pixelY: 200)

        #expect(delegate.text == "\u{1b}[<48;30;20m")
    }

    // MARK: - The application teardown sequence really turns tracking off

    /// Byte-for-byte what opencode 1.18 writes when it is killed with Ctrl+C,
    /// captured from a pty.  Any of these being mishandled would leave mouse
    /// reporting on and spray `48;30;20m`-style junk onto the shell prompt.
    @Test func openCodeTeardownSequenceDisablesMouseReporting() {
        let (terminal, delegate) = makeTerminal()
        feed(terminal, "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h")
        #expect(terminal.mouseMode == .anyEvent)

        let teardown = "\u{1b}]0;\u{7}\u{1b}[?25h\u{1b}[0m\u{1b}]22;\u{7}\u{1b}[>4;0m"
            + "\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l"
            + "\u{1b}[?2004l\u{1b}[?1049l\u{1b}[?2031l"
            + "\u{1b}]0;\u{7}\u{1b}]12;default\u{7}\u{1b}]112\u{7}\u{1b}[0 q\u{1b}[?25h"
        feed(terminal, teardown)
        #expect(terminal.mouseMode == .off)

        delegate.reset()
        terminal.sendMotion(buttonFlags: 19, x: 40, y: 10, pixelX: 400, pixelY: 100)
        // `mouseMode == .off` is what the views gate on; nothing may be queued
        // behind the teardown either.
        #expect(delegate.sent.isEmpty || terminal.mouseMode == .off)
    }

    /// The teardown arrives from a pty in whatever slices the kernel hands over.
    @Test func teardownSurvivesByteAtATimeDelivery() {
        let (terminal, _) = makeTerminal()
        feed(terminal, "\u{1b}[?1003h\u{1b}[?1006h")
        #expect(terminal.mouseMode == .anyEvent)

        let teardown = "\u{1b}]22;\u{7}\u{1b}[>4;0m\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?1049l"
        for byte in Array(teardown.utf8) {
            terminal.feed(byteArray: [byte])
        }
        #expect(terminal.mouseMode == .off)
    }
}
#endif
