import XCTest

/// Source-based i18n guard for macOS Claw Store strings that are not caught by
/// catalog-only coverage. It reads the app sources from disk so this SwiftPM
/// test target does not need to link the AppKit app target.
final class MacClawStoreI18nSourceCoverageTests: XCTestCase {
    private struct LocalizedReference: Comparable, CustomStringConvertible {
        let file: String
        let line: Int
        let key: String

        var description: String {
            "\(file):\(line) \(key)"
        }

        static func < (lhs: LocalizedReference, rhs: LocalizedReference) -> Bool {
            if lhs.file != rhs.file { return lhs.file < rhs.file }
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            return lhs.key < rhs.key
        }
    }

    func test_localizedDefaultValueKeysExistInMacCatalog() throws {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let clawStore = terminalApp
            .appendingPathComponent("SoyehtMac")
            .appendingPathComponent("ClawStore")
        let catalog = terminalApp
            .appendingPathComponent("SoyehtMac")
            .appendingPathComponent("Localizable.xcstrings")

        let catalogKeys = try loadCatalogKeys(catalog)
        let references = try localizedReferences(in: clawStore, relativeTo: terminalApp)
        let missing = references.filter { !catalogKeys.contains($0.key) }.sorted()

        XCTAssertTrue(
            missing.isEmpty,
            "\n" + missing.map(\.description).joined(separator: "\n")
        )
    }

    // MARK: - Source scanner

    private func localizedReferences(in directory: URL, relativeTo root: URL) throws -> [LocalizedReference] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(files.isEmpty, "Expected macOS Claw Store Swift files at \(directory.path)")

        let localizedStringResource = try NSRegularExpression(
            pattern: #"LocalizedStringResource\s*\(\s*"((?:\\.|[^"\\])*)"\s*,[^)]*?\bdefaultValue\s*:"#,
            options: [.dotMatchesLineSeparators]
        )
        let stringLocalized = try NSRegularExpression(
            pattern: #"String\s*\(\s*localized\s*:\s*"((?:\\.|[^"\\])*)"\s*,[^)]*?\bdefaultValue\s*:"#,
            options: [.dotMatchesLineSeparators]
        )

        var references: [LocalizedReference] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let codeOnly = stripCommentsPreservingLineNumbers(source)
            let relativePath = relativePath(for: file, root: root)
            for regex in [localizedStringResource, stringLocalized] {
                let range = NSRange(codeOnly.startIndex..<codeOnly.endIndex, in: codeOnly)
                for match in regex.matches(in: codeOnly, range: range) {
                    guard let keyRange = Range(match.range(at: 1), in: codeOnly) else { continue }
                    let key = String(codeOnly[keyRange])
                    references.append(LocalizedReference(
                        file: relativePath,
                        line: lineNumber(in: codeOnly, at: keyRange.lowerBound),
                        key: key
                    ))
                }
            }
        }
        return references
    }

    private func stripCommentsPreservingLineNumbers(_ source: String) -> String {
        enum State {
            case code
            case string(escaped: Bool)
            case lineComment
            case blockComment
        }

        var result = ""
        var state = State.code
        var index = source.startIndex

        func nextIndex(after index: String.Index) -> String.Index {
            source.index(after: index)
        }

        while index < source.endIndex {
            let char = source[index]
            let next = nextIndex(after: index)
            let nextChar = next < source.endIndex ? source[next] : nil

            switch state {
            case .code:
                if char == "/", nextChar == "/" {
                    result.append("  ")
                    index = source.index(index, offsetBy: 2)
                    state = .lineComment
                } else if char == "/", nextChar == "*" {
                    result.append("  ")
                    index = source.index(index, offsetBy: 2)
                    state = .blockComment
                } else {
                    result.append(char)
                    if char == "\"" {
                        state = .string(escaped: false)
                    }
                    index = next
                }

            case .string(let escaped):
                result.append(char)
                if escaped {
                    state = .string(escaped: false)
                } else if char == "\\" {
                    state = .string(escaped: true)
                } else if char == "\"" {
                    state = .code
                }
                index = next

            case .lineComment:
                if char == "\n" {
                    result.append(char)
                    state = .code
                } else {
                    result.append(" ")
                }
                index = next

            case .blockComment:
                if char == "*", nextChar == "/" {
                    result.append("  ")
                    index = source.index(index, offsetBy: 2)
                    state = .code
                } else {
                    result.append(char == "\n" ? "\n" : " ")
                    index = next
                }
            }
        }

        return result
    }

    private func lineNumber(in source: String, at index: String.Index) -> Int {
        source[..<index].reduce(1) { line, char in
            char == "\n" ? line + 1 : line
        }
    }

    private func relativePath(for file: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if file.path.hasPrefix(rootPath) {
            return String(file.path.dropFirst(rootPath.count))
        }
        return file.path
    }

    // MARK: - Catalog parser

    private func loadCatalogKeys(_ catalog: URL) throws -> Set<String> {
        let data = try Data(contentsOf: catalog)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any],
              let strings = dict["strings"] as? [String: Any] else {
            XCTFail("\(catalog.lastPathComponent) has no `strings` map")
            return []
        }
        return Set(strings.keys)
    }
}
