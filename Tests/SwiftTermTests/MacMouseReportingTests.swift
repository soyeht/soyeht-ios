//
//  MacMouseReportingTests.swift
//
//  Covers the two view-level halves of mouse reporting that the emulator-level
//  tests cannot reach: the `allowMouseReporting` gate and the buffer-row to
//  screen-row rebase, both on the hover (`mouseMoved`) path.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
final class SwiftTermMacMouseReporting {
    /// Records what the view sends back to the process.
    private final class ViewDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        var text: String { String(decoding: sent, as: UTF8.self) }
        func reset() { sent.removeAll() }
    }

    /// A borderless window keeps window coordinates and content-view coordinates
    /// aligned, which is what `isMouseEventForUs` hit-tests against.
    private func makeView() -> (TerminalView, ViewDelegate, NSWindow) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = TerminalView(frame: frame)
        let delegate = ViewDelegate()
        view.terminalDelegate = delegate
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, delegate, window)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// `CSI ? 1003 h` + `CSI ? 1006 h`: any-motion tracking, SGR encoding.
    private func enableTracking(_ view: TerminalView) {
        view.feed(byteArray: Array("\u{1b}[?1003h\u{1b}[?1006h".utf8)[...])
    }

    private func reportedRow(from text: String) -> Int? {
        // ESC [ < flags ; col ; row (M|m)
        guard let m = text.range(of: "<") else { return nil }
        let fields = text[m.upperBound...].dropLast().split(separator: ";")
        guard fields.count == 3 else { return nil }
        return Int(fields[2])
    }

    // MARK: - The gate

    @Test func hoverMotionHonorsAllowMouseReporting() {
        let (view, delegate, window) = makeView()
        enableTracking(view)
        view.allowMouseReporting = false
        delegate.reset()

        view.mouseMoved(with: event(.mouseMoved, at: NSPoint(x: 100, y: 200), in: window))
        view.mouseMoved(with: event(.mouseMoved, at: NSPoint(x: 140, y: 260), in: window))

        // Every other reporting path already obeyed this switch; hover must too.
        #expect(delegate.sent.isEmpty)
    }

    @Test func hoverMotionReportsWhenReportingIsAllowed() {
        let (view, delegate, window) = makeView()
        enableTracking(view)
        view.allowMouseReporting = true
        delegate.reset()

        view.mouseMoved(with: event(.mouseMoved, at: NSPoint(x: 100, y: 200), in: window))

        // Guards the test above from passing for the wrong reason.
        #expect(delegate.text.hasPrefix("\u{1b}[<"))
    }

    // MARK: - The rebase

    @Test func hoverMotionReportsScreenRowsWhileScrolledBack() {
        let (view, delegate, window) = makeView()
        // Enough output to build scrollback, then look at an older screenful.
        for i in 0 ..< 400 {
            view.feed(text: "line \(i)\r\n")
        }
        enableTracking(view)
        let buffer = view.getTerminal().displayBuffer
        buffer.yDisp = max(0, buffer.yBase - 50)
        #expect(buffer.yDisp > 0)

        let point = NSPoint(x: 100, y: 200)
        delegate.reset()
        view.mouseMoved(with: event(.mouseMoved, at: point, in: window))
        let hoverRow = reportedRow(from: delegate.text)

        // A press at the same point has always reported screen rows; hover must
        // agree with it instead of naming a row in the scrollback.
        delegate.reset()
        view.mouseDown(with: event(.leftMouseDown, at: point, in: window))
        let pressRow = reportedRow(from: delegate.text)

        #expect(hoverRow != nil)
        #expect(pressRow != nil)
        #expect(hoverRow == pressRow)
        if let hoverRow {
            #expect(hoverRow >= 1 && hoverRow <= view.getTerminal().rows)
        }
    }
}
#endif
