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

    private struct LookupPattern {
        let regex: NSRegularExpression
    }

    func test_localizedLiteralKeysExistInMacCatalog() throws {
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

    func test_sourceScannerCapturesCommonLiteralLookupsAndIgnoresComments() throws {
        let source = #"""
        Text("claw.store.loading")
        Button("common.button.ok") {}
        .help("claw.store.toolbar.reload.help")
        _ = String(localized: "drawer.search.store")
        _ = String(localized: "drawer.install.unavailable", defaultValue: "Install unavailable")
        _ = LocalizedStringResource("claw.store.header.subtitle")
        _ = LocalizedStringResource("claw.store.error.openServers", defaultValue: "Open Connected Servers")
        // Text("missing.line.comment")
        /*
         Button("missing.block.comment")
         */
        Text("ignored \(dynamic)")
        Text(dynamicKey)
        """#

        let references = try localizedReferences(in: source, relativePath: "Fixture.swift")

        XCTAssertEqual(
            references,
            [
                LocalizedReference(file: "Fixture.swift", line: 1, key: "claw.store.loading"),
                LocalizedReference(file: "Fixture.swift", line: 2, key: "common.button.ok"),
                LocalizedReference(file: "Fixture.swift", line: 3, key: "claw.store.toolbar.reload.help"),
                LocalizedReference(file: "Fixture.swift", line: 4, key: "drawer.search.store"),
                LocalizedReference(file: "Fixture.swift", line: 5, key: "drawer.install.unavailable"),
                LocalizedReference(file: "Fixture.swift", line: 6, key: "claw.store.header.subtitle"),
                LocalizedReference(file: "Fixture.swift", line: 7, key: "claw.store.error.openServers"),
            ]
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

        var references: [LocalizedReference] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = relativePath(for: file, root: root)
            references.append(contentsOf: try localizedReferences(in: source, relativePath: relativePath))
        }
        return references
    }

    private func localizedReferences(in source: String, relativePath: String) throws -> [LocalizedReference] {
        let codeOnly = stripCommentsPreservingLineNumbers(source)
        let patterns = try localizedLookupPatterns()
        var references: [LocalizedReference] = []
        for pattern in patterns {
            let range = NSRange(codeOnly.startIndex..<codeOnly.endIndex, in: codeOnly)
            for match in pattern.regex.matches(in: codeOnly, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: codeOnly) else { continue }
                let key = String(codeOnly[keyRange])
                if key.contains(#"\("#) { continue }
                references.append(LocalizedReference(
                    file: relativePath,
                    line: lineNumber(in: codeOnly, at: keyRange.lowerBound),
                    key: key
                ))
            }
        }
        return references.sorted()
    }

    private func localizedLookupPatterns() throws -> [LookupPattern] {
        let literal = #""((?:\\.|[^"\\])*)""#
        let options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        return try [
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\bLocalizedStringResource\s*\(\s*\#(literal)"#,
                    options: options
                )
            ),
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\bString\s*\(\s*localized\s*:\s*\#(literal)"#,
                    options: options
                )
            ),
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\bText\s*\(\s*\#(literal)"#,
                    options: options
                )
            ),
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\bButton\s*\(\s*\#(literal)"#,
                    options: options
                )
            ),
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\.help\s*\(\s*\#(literal)"#,
                    options: options
                )
            ),
        ]
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
