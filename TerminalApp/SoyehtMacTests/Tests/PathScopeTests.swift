import XCTest
@testable import SoyehtMacDomain

/// Phase 2a acceptance §2: the escape vectors must FAIL. Every test here
/// builds a real directory tree on disk, so the kernel — not a string
/// comparison — is what the test exercises.
final class PathScopeTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathScope-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        try "legit".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "in-sub".write(to: root.appendingPathComponent("sub-file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "nested".write(to: root.appendingPathComponent("sub/nested.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        // Symlinked trees must be removed without following links.
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeScope() throws -> PathScope {
        try PathScope(rootDirectory: root)
    }

    private func readAll(_ fd: Int32) throws -> String {
        defer { Darwin.close(fd) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
    }

    // MARK: - Legitimate access works

    func testOpensFileAtRoot() throws {
        let scope = try makeScope()
        XCTAssertEqual(try readAll(try scope.openFileForReading(relativePath: "file.txt")), "legit")
    }

    func testOpensNestedFile() throws {
        let scope = try makeScope()
        XCTAssertEqual(try readAll(try scope.openFileForReading(relativePath: "sub/nested.txt")), "nested")
    }

    // MARK: - Escape by parent reference must fail

    func testParentReferenceLiteralFails() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "../outside/secret.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .parentReference(".."))
        }
    }

    func testParentReferenceDeepInsidePathFails() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "sub/../../outside/secret.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .parentReference(".."))
        }
    }

    /// A component merely STARTING with `..` is refused — this closes
    /// `file/..namedfork/rsrc` (resource forks) and `...` style oddities
    /// with one rule instead of an enumeration.
    func testParentReferencePrefixFailsIncludingNamedFork() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "file.txt/..namedfork/rsrc")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .parentReference("..namedfork"))
        }
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "sub/...")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .parentReference("..."))
        }
    }

    // MARK: - Absolute paths must fail, with AND without symlinks on them

    /// `/etc/hosts` has a symlink (`/etc` → `/private/etc`) in its path.
    /// Rejection here proves the rule, but is NOT the strong case — see
    /// the contract's footnote: with a symlink first, even
    /// `O_NOFOLLOW_ANY` alone would refuse.
    func testAbsolutePathWithSymlinkInPathFails() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "/etc/hosts")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .absolutePath("/etc/hosts"))
        }
    }

    /// `/private/etc/hosts` is the same file with NO symlink on the way —
    /// `O_NOFOLLOW_ANY` alone would OPEN it (measured in the contract
    /// table). Refusal here is `O_RESOLVE_BENEATH`'s confinement by
    /// design; this test is the one that would catch someone "optimizing"
    /// the flags away.
    func testAbsolutePathWithoutSymlinkInPathFails() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "/private/etc/hosts")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .absolutePath("/private/etc/hosts"))
        }
    }

    // MARK: - Symlink escapes must fail in every position, distinguishably

    private func link(_ at: String, to target: URL) throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(at),
            withDestinationURL: target
        )
    }

    func testSymlinkAsLastComponentFailsNamingComponent() throws {
        try link("lure.txt", to: outside.appendingPathComponent("secret.txt"))
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "lure.txt")) { error in
            XCTAssertEqual(
                error as? PathScope.PathScopeError,
                .symlinkComponent("lure.txt"),
                "symlink refusal must be distinguishable and name the component"
            )
        }
    }

    func testSymlinkAsFirstComponentFailsNamingComponent() throws {
        try link("sub-link", to: root.appendingPathComponent("sub"))
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "sub-link/nested.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .symlinkComponent("sub-link"))
        }
    }

    func testSymlinkInMiddleOfPathFailsNamingComponent() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a", isDirectory: true), withIntermediateDirectories: true)
        try link("a/escape", to: outside)
        try "beyond".write(to: outside.appendingPathComponent("beyond.txt"), atomically: true, encoding: .utf8)
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "a/escape/beyond.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .symlinkComponent("escape"))
        }
    }

    /// Even a symlink that stays INSIDE the scope is refused: the rule is
    /// fail-closed on symlinks, period (contract: explicit error, expected
    /// behavior — not a bug to "fix" later).
    func testSymlinkPointingInsideScopeAlsoFails() throws {
        try link("inner.txt", to: root.appendingPathComponent("file.txt"))
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "inner.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .symlinkComponent("inner.txt"))
        }
    }

    // MARK: - Malformed relative paths

    func testEmptyPathFails() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .emptyPath)
        }
    }

    func testEmptyComponentFails() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "sub//nested.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .emptyComponent("sub//nested.txt"))
        }
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "file.txt/")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .emptyComponent("file.txt/"))
        }
    }

    func testMissingFileFailsAsNotFound() throws {
        let scope = try makeScope()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "no-such-file.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .notFound("no-such-file.txt"))
        }
    }

    // MARK: - Lifecycle: closed scopes never act, never double-close

    func testClosedScopeRefusesFurtherOpens() throws {
        let scope = try makeScope()
        scope.close()
        XCTAssertThrowsError(try scope.openFileForReading(relativePath: "file.txt")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .closed)
        }
    }

    func testCloseIsIdempotent() throws {
        let scope = try makeScope()
        scope.close()
        scope.close()
    }

    /// After revocation, a NEW scope on the same root works — proving the
    /// old (possibly recycled) fd number was never touched again.
    func testNewScopeAfterCloseWorksIndependently() throws {
        let first = try makeScope()
        _ = try first.openFileForReading(relativePath: "file.txt")
        first.close()

        let second = try makeScope()
        XCTAssertEqual(try readAll(try second.openFileForReading(relativePath: "sub/nested.txt")), "nested")
        second.close()
    }

    // MARK: - Root validation

    func testNonDirectoryRootIsRejected() throws {
        XCTAssertThrowsError(try PathScope(rootDirectory: root.appendingPathComponent("file.txt"))) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .invalidRoot)
        }
    }

    // MARK: - Directory listing (installer walk primitive)

    /// The fingerprint-coverage fix depends on this: hidden files MUST
    /// appear in a kernel listing, unlike `contentsOfDirectory` with
    /// `.skipsHiddenFiles`. What's on disk is what gets measured.
    func testListingIncludesHiddenFiles() throws {
        try "hidden".write(to: root.appendingPathComponent(".payload.js"), atomically: true, encoding: .utf8)
        let scope = try makeScope()

        let entries = try scope.listDirectoryEntries(relativePath: ".")

        let names = entries.map(\.name)
        XCTAssertTrue(names.contains(".payload.js"), "hidden files must be listed — fingerprint coverage")
        XCTAssertTrue(names.contains("file.txt"))
        XCTAssertTrue(names.contains("sub"))
        XCTAssertEqual(names, names.sorted(), "listing must be deterministic (sorted by name)")
    }

    func testListingReportsEntryKinds() throws {
        let scope = try makeScope()

        let entries = try scope.listDirectoryEntries(relativePath: ".")

        XCTAssertEqual(entries.first(where: { $0.name == "file.txt" })?.kind, .file)
        XCTAssertEqual(entries.first(where: { $0.name == "sub" })?.kind, .directory)
    }

    /// Symlink entries are visible as `.other` — naming them is required
    /// so the walker can fail loudly on them, but they are never openable.
    func testListingSurfacesSymlinkAsOtherKind() throws {
        try link("lure.txt", to: outside.appendingPathComponent("secret.txt"))
        let scope = try makeScope()

        let entries = try scope.listDirectoryEntries(relativePath: ".")

        XCTAssertEqual(entries.first(where: { $0.name == "lure.txt" })?.kind, .other)
    }

    func testListingSubdirectory() throws {
        let scope = try makeScope()

        let entries = try scope.listDirectoryEntries(relativePath: "sub")

        XCTAssertEqual(entries.map(\.name), ["nested.txt"])
        XCTAssertEqual(entries.first?.kind, .file)
    }

    func testOpenDirectoryForListingReturnsClosableDescriptor() throws {
        let scope = try makeScope()
        let fd = try scope.openDirectoryForListing(relativePath: "sub")
        XCTAssertGreaterThanOrEqual(fd, 0)
        Darwin.close(fd)
    }

    /// The walk primitive fails on the SAME escape vectors as file opens —
    /// it is the path receiving externally-pointed directories, so `..`,
    /// absolutes, and symlinked components must never become listable.
    func testDirectoryListingEscapeVectorsFail() throws {
        try link("sub-link", to: root.appendingPathComponent("sub"))
        let scope = try makeScope()

        XCTAssertThrowsError(try scope.openDirectoryForListing(relativePath: "../outside")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .parentReference(".."))
        }
        XCTAssertThrowsError(try scope.openDirectoryForListing(relativePath: "/private/etc")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .absolutePath("/private/etc"))
        }
        XCTAssertThrowsError(try scope.openDirectoryForListing(relativePath: "sub-link")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .symlinkComponent("sub-link"))
        }
    }

    func testClosedScopeRefusesListing() throws {
        let scope = try makeScope()
        scope.close()
        XCTAssertThrowsError(try scope.listDirectoryEntries(relativePath: ".")) { error in
            XCTAssertEqual(error as? PathScope.PathScopeError, .closed)
        }
    }
}
