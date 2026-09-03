import XCTest

/// Code→catalog half of the i18n gate.
///
/// `I18nCatalogCoverageTests` proves every catalog key carries all 17 locales,
/// but a key that exists only as an inline literal in code is invisible to it.
/// This test scans the onboarding / home / settings / welcome / preferences
/// sources from disk (like `MacClawStoreI18nSourceCoverageTests`, so the SwiftPM
/// test target never links the app targets) and proves every localized literal
/// has an entry in its owning catalog.
///
/// Keys that predate the gate live in `Fixtures/i18n-code-only-keys.txt`. That
/// allowlist may only shrink: the test fails on a new unlisted key, and it also
/// fails when an allowlisted key is no longer referenced or now has a catalog
/// entry, so stale lines cannot linger.
final class I18nSourceKeyCoverageTests: XCTestCase {
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

    /// A source root (directory scanned recursively, or a single file), relative
    /// to `TerminalApp/`, and the catalog its keys must live in.
    private struct Scope {
        let path: String
        let catalog: URL
    }

    // MARK: - Paths

    // #filePath = .../TerminalApp/SoyehtMacTests/Tests/I18nSourceKeyCoverageTests.swift
    private static let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/

    private static let terminalApp = testsDirectory
        .deletingLastPathComponent()  // SoyehtMacTests/
        .deletingLastPathComponent()  // TerminalApp/

    private static let repoRoot = terminalApp.deletingLastPathComponent()

    private static let iOSCatalog = terminalApp.appendingPathComponent("Soyeht/Localizable.xcstrings")
    private static let macCatalog = terminalApp.appendingPathComponent("SoyehtMac/Localizable.xcstrings")
    private static let coreCatalog = repoRoot.appendingPathComponent(
        "Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings"
    )

    private static let allowlistFixture = testsDirectory.appendingPathComponent("Fixtures/i18n-code-only-keys.txt")
    private static let allowlistFixtureName = "Tests/Fixtures/i18n-code-only-keys.txt"

    private static let scopes: [Scope] = [
        Scope(path: "Soyeht/Onboarding", catalog: iOSCatalog),
        Scope(path: "Soyeht/Home", catalog: iOSCatalog),
        Scope(path: "Soyeht/App", catalog: iOSCatalog),
        Scope(path: "Soyeht/Settings", catalog: iOSCatalog),
        Scope(path: "SoyehtMac/Welcome", catalog: macCatalog),
        Scope(path: "SoyehtMac/PreferencesDevicesViewController.swift", catalog: macCatalog),
    ]

    // MARK: - Gate

    func test_localizedLiteralKeysExistInOwningCatalogOrAllowlist() throws {
        let coreKeys = try loadCatalogKeys(Self.coreCatalog)
        var catalogKeysByURL: [URL: Set<String>] = [:]

        var referencedKeys = Set<String>()
        var unresolved: [LocalizedReference] = []

        for scope in Self.scopes {
            let root = Self.terminalApp.appendingPathComponent(scope.path)
            let files = try swiftFiles(at: root)
            XCTAssertFalse(files.isEmpty, "Expected Swift sources at \(root.path)")

            let catalogKeys: Set<String>
            if let cached = catalogKeysByURL[scope.catalog] {
                catalogKeys = cached
            } else {
                catalogKeys = try loadCatalogKeys(scope.catalog)
                catalogKeysByURL[scope.catalog] = catalogKeys
            }

            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                let relativePath = relativePath(for: file, root: Self.terminalApp)
                for reference in try localizedReferences(in: source, relativePath: relativePath) {
                    referencedKeys.insert(reference.key)
                    if !catalogKeys.contains(reference.key), !coreKeys.contains(reference.key) {
                        unresolved.append(reference)
                    }
                }
            }
        }

        let allowlist = try loadAllowlist()
        let allowlisted = Set(allowlist)

        // 0. The list may only shrink in SIZE too. Without this, a new
        //    code-only key could be added to the source and to the fixture in
        //    the same change and every other assertion would still pass.
        XCTAssertLessThanOrEqual(
            allowlist.count,
            Self.allowlistCeiling,
            "\(Self.allowlistFixtureName) has \(allowlist.count) keys and the ceiling is \(Self.allowlistCeiling). "
                + "Give the new key a catalog entry with all 17 locales instead. "
                + "When you delete lines, lower allowlistCeiling to match."
        )

        // 1. New code-only keys: not in the owning catalog, not allowlisted.
        let missing = unresolved.filter { !allowlisted.contains($0.key) }.sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "Localized keys with no entry in their owning Localizable.xcstrings (paths relative to TerminalApp/). "
                + "Add each key to the catalog with all 17 locales — do not add it to \(Self.allowlistFixtureName):\n"
                + missing.map(\.description).joined(separator: "\n")
        )

        // 2. Allowlist may only shrink: a line whose key no scanned source references any more.
        let unreferenced = allowlist.filter { !referencedKeys.contains($0) }
        XCTAssertTrue(
            unreferenced.isEmpty,
            "Allowlisted keys that are no longer referenced by any scanned source. "
                + "Delete these lines from \(Self.allowlistFixtureName):\n"
                + unreferenced.joined(separator: "\n")
        )

        // 3. Allowlist may only shrink: a line whose key now resolves in a catalog.
        let unresolvedKeys = Set(unresolved.map(\.key))
        let nowInCatalog = allowlist.filter { referencedKeys.contains($0) && !unresolvedKeys.contains($0) }
        XCTAssertTrue(
            nowInCatalog.isEmpty,
            "Allowlisted keys that now exist in their catalog. "
                + "Delete these lines from \(Self.allowlistFixtureName):\n"
                + nowInCatalog.joined(separator: "\n")
        )
    }

    /// Lower this every time lines leave the fixture; never raise it. S11
    /// takes it to zero.
    private static let allowlistCeiling = 170

    func test_allowlistFixtureIsSortedAndUnique() throws {
        let allowlist = try loadAllowlist()
        let outOfOrder = zip(allowlist, allowlist.dropFirst())
            .filter { !$0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            .map { "\($0) >= \($1)" }
        XCTAssertTrue(
            outOfOrder.isEmpty,
            "\(Self.allowlistFixtureName) must be sorted by code point with no duplicates (`LC_ALL=C sort -u`):\n"
                + outOfOrder.joined(separator: "\n")
        )
    }

    // MARK: - Scanner self-tests (pin the regexes and the enumerator)

    func test_sourceScannerCapturesCommonLiteralLookupsAndIgnoresComments() throws {
        let source = #"""
        Text("onboarding.loading")
        Button("common.button.ok") {}
        .help("prefs.devices.startOver.help")
        _ = String(localized: "prefs.tab.general")
        _ = String(localized: "prefs.tab.devices", defaultValue: "Devices")
        _ = LocalizedStringResource("welcome.joinChoice.title")
        _ = LocalizedStringResource("welcome.joinChoice.subtitle", defaultValue: "Pick one")
        Text(LocalizedStringResource(
            "addDevice.title",
            defaultValue: "Add a device"
        ))
        // Text("missing.line.comment")
        /*
         Button("missing.block.comment")
         */
        Text("ignored \(dynamic)")
        Text(dynamicKey)
        Text("🏠")
        Text("Not a key, just English")
        """#

        let references = try localizedReferences(in: source, relativePath: "Fixture.swift")

        XCTAssertEqual(
            references,
            [
                LocalizedReference(file: "Fixture.swift", line: 1, key: "onboarding.loading"),
                LocalizedReference(file: "Fixture.swift", line: 2, key: "common.button.ok"),
                LocalizedReference(file: "Fixture.swift", line: 3, key: "prefs.devices.startOver.help"),
                LocalizedReference(file: "Fixture.swift", line: 4, key: "prefs.tab.general"),
                LocalizedReference(file: "Fixture.swift", line: 5, key: "prefs.tab.devices"),
                LocalizedReference(file: "Fixture.swift", line: 6, key: "welcome.joinChoice.title"),
                LocalizedReference(file: "Fixture.swift", line: 7, key: "welcome.joinChoice.subtitle"),
                LocalizedReference(file: "Fixture.swift", line: 9, key: "addDevice.title"),
            ]
        )
    }

    func test_recursiveEnumeratorFindsNestedSwiftAndSkipsHiddenAndBuildDirectories() throws {
        // Canonicalize the temp dir with realpath(3) up front: on macOS it is
        // /var/... but the enumerator hands back /private/var/..., which would
        // defeat relativePath. (URL.resolvingSymlinksInPath deliberately keeps
        // the /var spelling, so it does not help here.)
        let tempPath = FileManager.default.temporaryDirectory.path
        let canonicalTempPath: String = {
            guard let cPath = realpath(tempPath, nil) else { return tempPath }
            defer { free(cPath) }
            return String(cString: cPath)
        }()
        let root = URL(fileURLWithPath: canonicalTempPath, isDirectory: true)
            .appendingPathComponent("I18nSourceKeyCoverageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let expected = ["Top.swift", "Nested/Deeper/Leaf.swift", "Nested/Mid.swift"]
        let ignored = [".hidden/Hidden.swift", ".build/Generated.swift", "Nested/.DS_Store.swift", "Nested/Notes.md"]
        for path in expected + ignored {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "".write(to: url, atomically: true, encoding: .utf8)
        }

        let found = try swiftFiles(at: root).map { relativePath(for: $0, root: root) }
        XCTAssertEqual(found, expected.sorted())

        let single = root.appendingPathComponent("Top.swift")
        XCTAssertEqual(try swiftFiles(at: single), [single])
    }

    // MARK: - Source scanner

    /// Recursive `.swift` enumeration under `root`, or `[root]` when it is a file.
    /// Skips hidden entries and `.build`, and returns a path-sorted list so the
    /// failure output is stable across runs.
    private func swiftFiles(at root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            XCTFail("Missing source root \(root.path)")
            return []
        }
        if !isDirectory.boolValue {
            return [root]
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if name.hasPrefix(".") || name == ".build" {
                    enumerator.skipDescendants()
                }
                continue
            }
            if name.hasPrefix(".") { continue }
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
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
                // A key in this codebase is dotted and lower-camel
                // (`bootstrap.welcome.title`). A plain English literal in a
                // debug view is a default string, not a lookup, and demanding
                // a catalog entry for it would only teach people to silence
                // the test.
                guard Self.looksLikeALocalizationKey(key) else { continue }
                references.append(LocalizedReference(
                    file: relativePath,
                    line: lineNumber(in: codeOnly, at: keyRange.lowerBound),
                    key: key
                ))
            }
        }
        return references.sorted()
    }

    static func looksLikeALocalizationKey(_ key: String) -> Bool {
        guard key.contains("."), !key.contains(" ") else { return false }
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            guard let first = segment.first, first.isLowercase || first.isNumber else { return false }
            return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
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
            // The rest of the SwiftUI views that take a title as their first
            // argument, plus the AppKit label factory Preferences uses. Their
            // literals are keys exactly like `Text`'s are.
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\b(?:Label|Toggle|TextField|SecureField|Section|Picker|Stepper|Link)\s*\(\s*\#(literal)"#,
                    options: options
                )
            ),
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\.navigationTitle\s*\(\s*\#(literal)"#,
                    options: options
                )
            ),
            LookupPattern(
                regex: NSRegularExpression(
                    pattern: #"\blabelWithString\s*:\s*\#(literal)"#,
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

    // MARK: - Fixture parser

    /// One key per line; blank lines and `#` comments are ignored. Returns the
    /// keys in file order so the sortedness check can report the first offender.
    private func loadAllowlist() throws -> [String] {
        let text = try String(contentsOf: Self.allowlistFixture, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
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
