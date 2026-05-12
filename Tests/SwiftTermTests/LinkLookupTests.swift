//
//  LinkLookupTests.swift
//
//
//  Created by Codex on 1/31/26.
//

import Foundation
#if os(macOS)
import AppKit
#endif
import Testing

@testable import SwiftTerm

final class LinkLookupTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

#if os(macOS)
    private final class LinkOpenDelegate: TerminalViewDelegate {
        var openedLink: String?

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            openedLink = link
        }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
#endif

    private func write(_ text: String, terminal: Terminal, row: Int, col: Int = 0) {
        guard row >= 0 && row < terminal.displayBuffer.lines.count else {
            return
        }
        let line = terminal.displayBuffer.lines[row]
        var x = col
        for ch in text {
            guard x < terminal.cols else { break }
            line[x] = terminal.makeCharData(attribute: CharData.defaultAttr, char: ch)
            x += 1
        }
    }

    @Test func testExplicitLinkLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "abc")

        let payload = "id;https://example.com"
        let atom = TinyAtom.lookup(value: payload)!
        let line = terminal.displayBuffer.lines[0]
        var cd = line[1]
        cd.setPayload(atom: atom)
        line[1] = cd

        let link = terminal.link(at: .buffer(Position(col: 1, row: 0)), mode: .explicitOnly)
        #expect(link == "https://example.com")
    }

    @Test func testImplicitUrlLookup() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 1))
        terminal.feed(text: "https://example.com tail")

        let link = terminal.link(at: .buffer(Position(col: 5, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "https://example.com")
    }

    @Test func testImplicitFilePathDoesNotMatch() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "/tmp/example.txt")

        let link = terminal.link(at: .buffer(Position(col: 2, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testImplicitUrlKeepsQueryAndFragment() {
        let url = "https://example.com/search?q=hello%20world&sort=asc#top"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 1))
        terminal.feed(text: "open \(url) now")

        let link = terminal.link(at: .buffer(Position(col: 22, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlKeepsPort() {
        let url = "http://localhost:3000/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: url)

        let link = terminal.link(at: .buffer(Position(col: 12, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlKeepsIPv4Host() {
        let url = "http://127.0.0.1:8080/health"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: url)

        let link = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlKeepsIPv6Host() {
        let url = "http://[::1]:8080/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: url)

        let link = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlKeepsDomainAndPathCharacters() {
        let url = "https://foo-bar.example.co.uk/a-b_c~d"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 70, rows: 1))
        terminal.feed(text: "visit \(url)")

        let link = terminal.link(at: .buffer(Position(col: 20, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlTrimsClosingParenthesisWrapper() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: "open (\(url))")

        let link = terminal.link(at: .buffer(Position(col: 12, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)

        let trailingParenthesis = terminal.link(at: .buffer(Position(col: 6 + url.count + 1, row: 0)), mode: .explicitAndImplicit)
        #expect(trailingParenthesis == nil)
    }

    @Test func testImplicitUrlKeepsBalancedParentheses() {
        let url = "https://example.com/foo(bar)"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: url)

        let link = terminal.link(at: .buffer(Position(col: url.count - 2, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlTrimsMarkdownClosingParenthesis() {
        let url = "https://example.com/docs"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: "[docs](\(url))")

        let link = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)
    }

    @Test func testImplicitUrlTrimsAngleBracketWrapper() {
        let url = "https://example.com/a"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 50, rows: 1))
        terminal.feed(text: "<\(url)>")

        let link = terminal.link(at: .buffer(Position(col: 3, row: 0)), mode: .explicitAndImplicit)
        #expect(link == url)

        let closingBracket = terminal.link(at: .buffer(Position(col: url.count + 1, row: 0)), mode: .explicitAndImplicit)
        #expect(closingBracket == nil)
    }

    @Test func testImplicitUrlTrimsTrailingSentencePunctuation() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 1))
        terminal.feed(text: "links: \(url), \(url). \(url)! \(url)? \(url);")

        #expect(terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit) == url)
        #expect(terminal.link(at: .buffer(Position(col: 33, row: 0)), mode: .explicitAndImplicit) == url)
        #expect(terminal.link(at: .buffer(Position(col: 56, row: 0)), mode: .explicitAndImplicit) == url)
    }

    @Test func testImplicitUrlDoesNotMatchTrailingPunctuationCell() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 1))
        terminal.feed(text: "\(url).")

        let punctuation = terminal.link(at: .buffer(Position(col: url.count, row: 0)), mode: .explicitAndImplicit)
        #expect(punctuation == nil)
    }

    @Test func testImplicitUrlRejectsSchemeWithoutHost() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "https:// tail")

        let link = terminal.link(at: .buffer(Position(col: 3, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testImplicitUrlRejectsEmptyHost() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "https://./path")

        let link = terminal.link(at: .buffer(Position(col: 4, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testImplicitEmailAddressDoesNotMatchWithoutMailtoScheme() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "user@example.com")

        let link = terminal.link(at: .buffer(Position(col: 5, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testImplicitVersionNumberDoesNotMatch() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "released v1.2.3")

        let link = terminal.link(at: .buffer(Position(col: 12, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testImplicitUrlLookupAcrossWrappedLines() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
        terminal.feed(text: url)

        let topRowLink = terminal.link(at: .buffer(Position(col: 2, row: 0)), mode: .explicitAndImplicit)
        #expect(topRowLink == url)

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 1, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == url)
    }

    @Test func testImplicitMatchReportsPerRowRangesAcrossWrap() {
        let url = "https://example.com/path"
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 8, rows: 4))
        terminal.feed(text: url)

        guard let match = terminal.linkMatch(at: .buffer(Position(col: 1, row: 1)), mode: .explicitAndImplicit) else {
            Issue.record("Expected implicit link match on wrapped row")
            return
        }
        #expect(match.text == url)
        #expect(match.rowRanges.count >= 2)
        #expect(match.rowRanges.contains { $0.row == 0 })
        #expect(match.rowRanges.contains { $0.row == 1 })
        #expect(match.rowRanges.first(where: { $0.row == 1 })?.range.contains(1) == true)
    }

    @Test func testImplicitUrlLookupAcrossWrappedContinuationWithIndentation() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        write("https://example.", terminal: terminal, row: 0)
        write("    com/path", terminal: terminal, row: 1)
        terminal.displayBuffer.lines[1].isWrapped = true

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 6, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == "https://example.com/path")
    }

    @Test func testImplicitUrlLookupAcrossEditorSoftWrapWithoutWrappedFlag() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 92, rows: 4))
        let firstSegment = "https://example.com/this/is/a/long/url/segment/that/reaches/the/visual/wrap/"
        write(firstSegment, terminal: terminal, row: 0)
        write("    and/keeps/going", terminal: terminal, row: 1)

        let firstRowLink = terminal.link(at: .buffer(Position(col: 20, row: 0)), mode: .explicitAndImplicit)
        #expect(firstRowLink == firstSegment + "and/keeps/going")

        let wrappedRowLink = terminal.link(at: .buffer(Position(col: 8, row: 1)), mode: .explicitAndImplicit)
        #expect(wrappedRowLink == firstSegment + "and/keeps/going")
    }

    @Test func testImplicitUrlLookupDoesNotJoinUnrelatedRows() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 92, rows: 3))
        write("https://example.com", terminal: terminal, row: 0)
        write("nextline", terminal: terminal, row: 1)

        let urlRowLink = terminal.link(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(urlRowLink == "https://example.com")

        let nextRowLink = terminal.link(at: .buffer(Position(col: 2, row: 1)), mode: .explicitAndImplicit)
        #expect(nextRowLink == nil)
    }

    @Test func testImplicitBareDomainDoesNotMatch() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 1))
        terminal.feed(text: "example.com")

        let link = terminal.link(at: .buffer(Position(col: 3, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testWhitespaceReturnsNil() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 1))
        terminal.feed(text: "a b")

        let link = terminal.link(at: .buffer(Position(col: 1, row: 0)), mode: .explicitAndImplicit)
        #expect(link == nil)
    }

    @Test func testScreenCoordinates() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 32, rows: 2))
        terminal.feed(text: "https://www.example.com")

        let link = terminal.link(at: .screen(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
        #expect(link == "https://www.example.com")
    }

#if os(macOS)
    @Test func testImplicitHoverLinkCanBeClickedWithoutStoredHighlight() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 120)))
        view.linkHighlightMode = .hover
        view.feed(text: "https://example.com")

        let result = view.linkForClick(at: Position(col: 5, row: 0), hasCommandModifier: false)
        #expect(result?.link == "https://example.com")
    }

    @Test func testImplicitHoverWithModifierRequiresModifierForClick() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 120)))
        view.linkHighlightMode = .hoverWithModifier
        view.feed(text: "https://example.com")

        let withoutModifier = view.linkForClick(at: Position(col: 5, row: 0), hasCommandModifier: false)
        #expect(withoutModifier == nil)

        let withModifier = view.linkForClick(at: Position(col: 5, row: 0), hasCommandModifier: true)
        #expect(withModifier?.link == "https://example.com")
    }

    @Test @MainActor func testMouseUpOnImplicitHoverLinkRequestsOpenLink() {
        let url = "https://example.com"
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 500, height: 160)))
        let delegate = LinkOpenDelegate()
        view.terminalDelegate = delegate
        view.linkHighlightMode = .hover
        view.feed(text: url)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        let clickPoint = CGPoint(
            x: view.cellDimension.width * 5,
            y: view.bounds.height - (view.cellDimension.height / 2)
        )
        let location = view.convert(clickPoint, to: nil)
        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )

        if let mouseDown, let mouseUp {
            view.mouseDown(with: mouseDown)
            view.mouseUp(with: mouseUp)
        } else {
            Issue.record("Expected AppKit to create synthetic mouse events")
        }

        #expect(delegate.openedLink == url)
    }
#endif
}
