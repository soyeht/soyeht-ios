import Foundation
import Testing
@testable import SoyehtCore

@Suite("BIP39Wordlist")
struct BIP39WordlistTests {
    @Test func loadsCanonicalEnglishResource() throws {
        let wordlist = try BIP39Wordlist()
        #expect(wordlist.count == BIP39Wordlist.expectedWordCount)
        #expect(wordlist.count == 2048)
    }

    @Test func firstAndLastWordsMatchCanonicalBIP0039() throws {
        let wordlist = try BIP39Wordlist()
        #expect(try wordlist.word(at: 0) == "abandon")
        #expect(try wordlist.word(at: 1) == "ability")
        #expect(try wordlist.word(at: 2) == "able")
        #expect(try wordlist.word(at: 2045) == "zero")
        #expect(try wordlist.word(at: 2046) == "zone")
        #expect(try wordlist.word(at: 2047) == "zoo")
    }

    @Test func indexOutOfRangeThrowsTypedError() throws {
        let wordlist = try BIP39Wordlist()
        do {
            _ = try wordlist.word(at: -1)
            Issue.record("Expected indexOutOfRange for negative index")
        } catch BIP39WordlistError.indexOutOfRange(let index) {
            #expect(index == -1)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        do {
            _ = try wordlist.word(at: 2048)
            Issue.record("Expected indexOutOfRange for length-equal index")
        } catch BIP39WordlistError.indexOutOfRange(let index) {
            #expect(index == 2048)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func wordCountMismatchSurfacesTypedError() throws {
        do {
            _ = try BIP39Wordlist(words: ["abandon", "ability"])
            Issue.record("Expected invalidWordCount error")
        } catch let BIP39WordlistError.invalidWordCount(expected, actual) {
            #expect(expected == 2048)
            #expect(actual == 2)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func batchWordsAtIndicesPreservesOrder() throws {
        let wordlist = try BIP39Wordlist()
        let words = try wordlist.words(at: [0, 2047, 1024])
        #expect(words == ["abandon", "zoo", try wordlist.word(at: 1024)])
    }
}
