import XCTest

/// Source guard for the iOS deploy timeout UX. The iOS app target can be
/// blocked locally by binary artifacts, so this SwiftPM test pins the important
/// source contract without linking ActivityKit.
final class IOSDeployTimeoutSourceGuardTests: XCTestCase {
    func test_deployMonitorTimeoutDoesNotSynthesizeFailure() throws {
        let source = try codeOnly(repoSource("Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawDeployMonitor.swift"))
        let timeoutBlock = try slice(
            source,
            from: "guard let self else { return }\n            activityManager.endActivity(",
            to: "self.removeDeploy(id: instanceId)"
        )

        XCTAssertTrue(timeoutBlock.contains("status: InstanceStatus.provisioning.rawValue"))
        XCTAssertTrue(timeoutBlock.contains("message: Self.stillPreparingMessage"))
        XCTAssertTrue(timeoutBlock.contains("phase: Self.checkLaterPhase"))
        XCTAssertTrue(timeoutBlock.contains("notifyDeployStillPreparing(clawName)"))
        XCTAssertFalse(timeoutBlock.contains("status: \"failed\""))
        XCTAssertFalse(timeoutBlock.contains("success: false"))
    }

    func test_activityPhaseMapsCheckLaterWithoutChangingFailedStatusContract() throws {
        let source = try codeOnly(repoSource("TerminalApp/Soyeht/ClawStore/ClawDeployAttributes.swift"))

        XCTAssertTrue(source.contains("case queuing, pulling, starting, checkLater, ready, failed"))
        XCTAssertTrue(source.contains("if status == \"failed\" { self = .failed; return }"))
        XCTAssertTrue(source.contains("case \"check_later\": self = .checkLater"))
    }

    // MARK: - Helpers

    private func repoSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return false }
                if trimmed.hasPrefix("*") { return false }
                if trimmed.hasPrefix("/*") { return false }
                return true
            }
            .joined(separator: "\n")
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
