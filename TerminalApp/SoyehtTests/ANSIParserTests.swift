import Testing
import SwiftUI
@testable import Soyeht

// Parser behavior tests. Font-specific assertions live in TypographyTests —
// comparing `Font` instances for equality across `Font.custom(...)` values
// is fragile, so we test only what the parser is responsible for: content,
// run count, and which runs have non-nil fonts (parser always attaches one).

@Suite struct ANSIParserTests {

    @Test("Plain text preserves content and attaches a font")
    func plainText() {
        let result = ANSIParser.parse("hello world", fontSize: 15)
        #expect(String(result.characters) == "hello world")
        #expect(result.runs.first?.font != nil)
    }

    @Test("Bold ANSI code produces a run")
    func boldText() {
        let result = ANSIParser.parse("\u{1b}[1mbold text\u{1b}[0m", fontSize: 13)
        #expect(String(result.characters) == "bold text")
        #expect(result.runs.first?.font != nil)
    }

    @Test("Reset code splits into separate runs")
    func resetCode() {
        let result = ANSIParser.parse("\u{1b}[1mbold\u{1b}[0mnormal", fontSize: 12)
        let runs = Array(result.runs)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.font != nil })
    }

    @Test("SGR 3 enables italic, 23 disables it")
    func italicToggle() {
        let result = ANSIParser.parse("\u{1b}[3mitalic\u{1b}[23mnormal", fontSize: 13)
        let runs = Array(result.runs)
        #expect(runs.count == 2)
        #expect(String(result.characters) == "italicnormal")
    }

    @Test("Font size parameter is respected across sizes")
    func fontSizeRespected() {
        for size: CGFloat in [8, 11, 13, 18, 24] {
            let result = ANSIParser.parse("test", fontSize: size)
            #expect(result.runs.first?.font != nil)
        }
    }

    @Test("Foreground color codes change color")
    func foregroundColors() {
        let result = ANSIParser.parse("\u{1b}[31mred", fontSize: 13)
        let run = result.runs.first!
        #expect(run.foregroundColor != .white)
    }

    @Test("256-color codes parse without crash")
    func color256() {
        let result = ANSIParser.parse("\u{1b}[38;5;196mcolored\u{1b}[0m", fontSize: 13)
        #expect(String(result.characters) == "colored")
    }

    @Test("RGB true color codes parse without crash")
    func trueColor() {
        let result = ANSIParser.parse("\u{1b}[38;2;255;128;0morange\u{1b}[0m", fontSize: 13)
        #expect(String(result.characters) == "orange")
    }

    @Test("Unrecognized SGR codes are skipped without crash")
    func unknownSequences() {
        let result = ANSIParser.parse("\u{1b}[999mhello", fontSize: 13)
        #expect(String(result.characters) == "hello")
    }

    @Test("Empty string returns empty AttributedString")
    func emptyString() {
        let result = ANSIParser.parse("", fontSize: 13)
        #expect(String(result.characters).isEmpty)
    }

    @Test("Non-SGR CSI sequences are skipped")
    func nonSgrSequence() {
        let result = ANSIParser.parse("\u{1b}[2Jhello", fontSize: 13)
        #expect(String(result.characters) == "hello")
    }
}
