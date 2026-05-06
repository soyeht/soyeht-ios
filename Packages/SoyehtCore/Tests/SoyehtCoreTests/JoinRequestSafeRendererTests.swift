import Foundation
import Testing
@testable import SoyehtCore

@Suite("JoinRequestSafeRenderer")
struct JoinRequestSafeRendererTests {
    private let renderer = JoinRequestSafeRenderer()

    @Test func passesThroughBenignAsciiUnchanged() {
        let result = renderer.render("studio.local")
        #expect(result == "studio.local")
    }

    @Test func stripsRTLOverrideSequences() {
        // Classic RLO attack: visually shows "studio[gpj.exe]" by reordering with U+202E.
        let attack = "studio\u{202E}exe.gpj"
        let result = renderer.render(attack)
        #expect(result == "studioexe.gpj")
        #expect(!result.unicodeScalars.contains("\u{202E}"))
    }

    @Test func stripsAllBidiOverrideAndIsolateScalars() {
        let scalars: [Unicode.Scalar] = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        ]
        for scalar in scalars {
            let payload = "host" + String(scalar) + "name"
            let result = renderer.render(payload)
            #expect(result == "hostname", "scalar U+\(String(scalar.value, radix: 16, uppercase: true)) leaked into output")
        }
    }

    @Test func replacesC0ControlCharactersWithReplacement() {
        let attack = "host\u{0007}name\u{001B}[31m"
        let result = renderer.render(attack)
        #expect(result == "host\u{FFFD}name\u{FFFD}[31m")
    }

    @Test func replacesDelAndC1ControlCharactersWithReplacement() {
        let attack = "host\u{007F}\u{0085}name"
        let result = renderer.render(attack)
        #expect(result == "host\u{FFFD}\u{FFFD}name")
    }

    @Test func truncatesOversizeInputAndPreservesTrustworthyPrefix() {
        let raw = "trustworthy-prefix-then-adversarial-suffix-trying-to-deceive-the-operator"
        let result = renderer.render(raw, maxCharacters: 16)
        #expect(result.count == 16)
        #expect(result.hasPrefix("trustworthy-pre"))
        #expect(result.hasSuffix("…"))
    }

    @Test func renderIsIdempotentUnderRepeatedApplication() {
        let raw = "host\u{202E}\u{0007}\u{007F}name-extending-beyond-the-cap-many-many-characters-here"
        let once = renderer.render(raw, maxCharacters: 32)
        let twice = renderer.render(once, maxCharacters: 32)
        let thrice = renderer.render(twice, maxCharacters: 32)
        #expect(once == twice)
        #expect(twice == thrice)
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(renderer.render("") == "")
    }

    @Test func zeroMaxCharactersYieldsEmptyOutput() {
        #expect(renderer.render("anything", maxCharacters: 0) == "")
    }

    @Test func mixedAttackVectorPreservesUsefulPrefixAndNeutralizesPayload() {
        // First five chars are the trustworthy region the operator should see.
        let raw = "stdio\u{202E}\u{0000}\u{2068}adversarial-suffix-trying-to-deceive"
        let result = renderer.render(raw, maxCharacters: 12)
        #expect(result.hasPrefix("stdio"))
        #expect(!result.unicodeScalars.contains("\u{202E}"))
        #expect(!result.unicodeScalars.contains("\u{2068}"))
        #expect(!result.unicodeScalars.contains("\u{0000}"))
        #expect(result.count == 12)
        #expect(result.hasSuffix("…"))
    }

    @Test func nonControlExtendedUnicodePassesThrough() {
        // Emoji and non-Latin scripts MUST NOT be neutralised — only control bytes are dangerous.
        let raw = "café-🚀-工作站"
        let result = renderer.render(raw)
        #expect(result == raw)
    }
}
