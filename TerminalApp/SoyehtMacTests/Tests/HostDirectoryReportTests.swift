import XCTest
@testable import SoyehtMacDomain

/// A pane that only remembers where it was OPENED comes back in the wrong
/// place the moment anyone types `cd` — which is most panes, most days. The
/// shells here (`/bin/bash`) announce nothing on their own, so the app puts
/// an OSC 7 report in the prompt it already sets and reads it back. These
/// tests hold both ends of that: what gets written, and what the app is
/// willing to believe when it comes back.
final class HostDirectoryReportTests: XCTestCase {

    // MARK: - What the shell sends

    func testAcceptsAFileURLWithAnEmptyAuthority() {
        XCTAssertEqual(
            HostDirectoryReport.localPath(fromOSC7: "file:///Users/someone/Documents"),
            "/Users/someone/Documents"
        )
    }

    func testIgnoresTheHostInAFileURL() {
        // A pane's shell reports its own machine; the name adds nothing and
        // must not stop the path from being read.
        XCTAssertEqual(
            HostDirectoryReport.localPath(fromOSC7: "file://somemac.local/Users/someone/src"),
            "/Users/someone/src"
        )
    }

    func testAcceptsABarePath() {
        XCTAssertEqual(
            HostDirectoryReport.localPath(fromOSC7: "/Users/someone/src"),
            "/Users/someone/src"
        )
    }

    func testDecodesPercentEncodedSpaces() {
        // The prompt encodes spaces; a path with one must survive the round
        // trip, or every pane under "Application Support" loses its folder.
        XCTAssertEqual(
            HostDirectoryReport.localPath(fromOSC7: "file:///Users/someone/My%20Projects/app"),
            "/Users/someone/My Projects/app"
        )
    }

    func testKeepsAPathThatIsNotValidPercentEncoding() {
        // `%` is legal in a filename. Losing the report over it would be
        // worse than keeping the raw bytes.
        XCTAssertEqual(
            HostDirectoryReport.localPath(fromOSC7: "file:///Users/someone/100%done"),
            "/Users/someone/100%done"
        )
    }

    func testUppercaseSchemeIsStillAFileURL() {
        XCTAssertEqual(
            HostDirectoryReport.localPath(fromOSC7: "FILE:///tmp"),
            "/tmp"
        )
    }

    func testDropsATrailingSlashButKeepsTheRoot() {
        XCTAssertEqual(HostDirectoryReport.localPath(fromOSC7: "file:///tmp/"), "/tmp")
        XCTAssertEqual(HostDirectoryReport.localPath(fromOSC7: "file:///"), "/")
    }

    // MARK: - What the app refuses

    func testRefusesARelativePath() {
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: "Documents/src"))
    }

    func testRefusesAnEmptyOrBlankPayload() {
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: ""))
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: "   \n"))
    }

    func testRefusesANonFileScheme() {
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: "http://example.com/x"))
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: "ssh://host/home/someone"))
    }

    func testRefusesAFileURLWithNoPath() {
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: "file://justahost"))
    }

    func testRefusesAPayloadCarryingANulByte() {
        XCTAssertNil(HostDirectoryReport.localPath(fromOSC7: "file:///tmp/\0evil"))
    }

    // MARK: - What goes into the prompt

    func testPromptPrefixIsAZeroWidthOSC7Report() {
        let prefix = HostDirectoryReport.bashPromptPrefix
        // Bash must be told the sequence prints nothing, or it miscounts the
        // prompt width and line editing wraps in the wrong column.
        XCTAssertTrue(prefix.hasPrefix(#"\["#))
        XCTAssertTrue(prefix.hasSuffix(#"\]"#))
        XCTAssertTrue(prefix.contains(#"\e]7;file://"#))
        XCTAssertTrue(prefix.contains(#"\a"#))
        // Spaces are the one character that realistically appears in a Mac
        // path and breaks a naive parse on the way back.
        XCTAssertTrue(prefix.contains("${PWD// /%20}"))
    }

    /// The report has to reach the shell the pane actually runs — and the
    /// engine-broker path builds its env from the same plan, so this covers
    /// persistent panes too.
    func testSpawnPlanPutsTheReportInFrontOfWhicheverPromptIsUsed() throws {
        let source = try macSource("SoyehtInstance/NativePTY.swift")
        XCTAssertTrue(
            source.contains("HostDirectoryReport.bashPromptPrefix + prompt"),
            "the OSC 7 report must prefix the person's own PS1 too"
        )
    }

    /// A syntactic parse is not permission to persist: a prompt with
    /// parameter expansion disabled reports its own source text.
    func testPersistingAReportedFolderChecksItExists() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let handler = try slice(
            source,
            from: "terminalView.onHostDirectoryChanged",
            to: "AppEnvironment.conversationStore?.updateWorkingDirectory"
        )
        XCTAssertTrue(handler.contains("FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)"))
        XCTAssertTrue(handler.contains("isDirectory.boolValue else { return }"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
