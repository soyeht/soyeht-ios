import Foundation

public enum BIP39WordlistError: Error, Equatable, Sendable {
    case resourceMissing
    case invalidEncoding
    case invalidWordCount(expected: Int, actual: Int)
    case indexOutOfRange(Int)
}

public struct BIP39Wordlist: Sendable {
    public static let expectedWordCount = 2048
    public static let resourceName = "bip39-en"
    public static let resourceExtension = "txt"

    private let words: [String]

    public init(words: [String]) throws {
        guard words.count == Self.expectedWordCount else {
            throw BIP39WordlistError.invalidWordCount(
                expected: Self.expectedWordCount,
                actual: words.count
            )
        }
        self.words = words
    }

    public init(bundle: Bundle = SoyehtCoreResources.bundle) throws {
        // The wordlist is a security-critical cryptographic primitive — only
        // accept the precise vendored path, never a same-named file
        // accidentally bundled elsewhere in the resource graph.
        guard let url = bundle.url(
            forResource: Self.resourceName,
            withExtension: Self.resourceExtension,
            subdirectory: "Wordlists"
        ) else {
            throw BIP39WordlistError.resourceMissing
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BIP39WordlistError.invalidEncoding
        }
        let split = text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" }
        try self.init(words: split.map(String.init))
    }

    public var count: Int { words.count }

    public func word(at index: Int) throws -> String {
        guard words.indices.contains(index) else {
            throw BIP39WordlistError.indexOutOfRange(index)
        }
        return words[index]
    }

    public func words(at indices: [Int]) throws -> [String] {
        try indices.map(word(at:))
    }
}
