import Testing
import SwiftUI
@testable import iOSTerminal

@Suite struct ANSIParserTests {

    @Test("Plain text preserves content and uses given font size")
    func plainText() {
        let result = ANSIParser.parse("hello world", fontSize: 15)
        let str = String(result.characters)
        #expect(str == "hello world")

        // Check font size
        let run = result.runs.first!
        let font = run.font
        #expect(font == .system(size: 15, weight: .regular, design: .monospaced))
    }

    @Test("Bold ANSI code applies bold weight")
    func boldText() {
        let result = ANSIParser.parse("\u{1b}[1mbold text\u{1b}[0m", fontSize: 13)
        let runs = Array(result.runs)
        let boldRun = runs.first!
        #expect(boldRun.font == .system(size: 13, weight: .bold, design: .monospaced))
    }

    @Test("Reset code restores defaults")
    func resetCode() {
        let result = ANSIParser.parse("\u{1b}[1mbold\u{1b}[0mnormal", fontSize: 12)
        let runs = Array(result.runs)
        #expect(runs.count == 2)
        // Second run should be normal weight
        #expect(runs[1].font == .system(size: 12, weight: .regular, design: .monospaced))
    }

    @Test("Font size parameter is respected, not hardcoded")
    func fontSizeRespected() {
        for size: CGFloat in [8, 11, 13, 18, 24] {
            let result = ANSIParser.parse("test", fontSize: size)
            let font = result.runs.first!.font
            #expect(font == .system(size: size, weight: .regular, design: .monospaced))
        }
    }

    @Test("Foreground color codes change color")
    func foregroundColors() {
        // Red text: ESC[31m
        let result = ANSIParser.parse("\u{1b}[31mred", fontSize: 13)
        let run = result.runs.first!
        // Should not be white (default)
        #expect(run.foregroundColor != .white)
    }

    @Test("256-color codes parse without crash")
    func color256() {
        // ESC[38;5;196m = 256-color red
        let result = ANSIParser.parse("\u{1b}[38;5;196mcolored\u{1b}[0m", fontSize: 13)
        let str = String(result.characters)
        #expect(str == "colored")
    }

    @Test("RGB true color codes parse without crash")
    func trueColor() {
        // ESC[38;2;255;128;0m = orange
        let result = ANSIParser.parse("\u{1b}[38;2;255;128;0morange\u{1b}[0m", fontSize: 13)
        let str = String(result.characters)
        #expect(str == "orange")
    }

    @Test("Unrecognized sequences are skipped without crash")
    func unknownSequences() {
        // ESC[999m is not a recognized SGR code — should not crash
        let result = ANSIParser.parse("\u{1b}[999mhello", fontSize: 13)
        let str = String(result.characters)
        #expect(str == "hello")
    }

    @Test("Empty string returns empty AttributedString")
    func emptyString() {
        let result = ANSIParser.parse("", fontSize: 13)
        #expect(String(result.characters).isEmpty)
    }

    @Test("Non-SGR CSI sequences are skipped")
    func nonSgrSequence() {
        // ESC[2J is "clear screen" — should be skipped, not crash
        let result = ANSIParser.parse("\u{1b}[2Jhello", fontSize: 13)
        let str = String(result.characters)
        #expect(str == "hello")
    }
}
