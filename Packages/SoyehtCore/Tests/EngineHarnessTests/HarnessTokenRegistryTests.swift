import Foundation
import XCTest

/// Proves the enum producers and the committed allowlist stay in exact lockstep,
/// that tokens are unique (no producer masquerades by reusing a token), and that
/// the RUNTIME registry (`EngineHarness.allHarnessTokens`) is the load-bearing
/// gate: the append refuses any token outside it. (The earlier source-scan of
/// conformers is demoted — it had declaration-form blind spots; write-point
/// validation is the real protection.)
final class HarnessTokenRegistryTests: XCTestCase {
    private func repoFile(_ relative: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // EngineHarnessTests -> repo root
        return url.appendingPathComponent(relative)
    }

    private func fileTokens() throws -> [String] {
        try String(contentsOf: repoFile("scripts/ci/harness-safe-stages.txt"), encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private var producerTokens: [String] {
        EngineHarness.HarnessCaseID.allCases.map(\.token)
            + EngineHarness.InitializeOutcome.allCases.map(\.token)
            + EngineHarness.InitiateOutcome.allCases.map(\.token)
    }

    func test_registry_equalsAllowlistFile() throws {
        XCTAssertEqual(Set(producerTokens), Set(try fileTokens()))
        XCTAssertEqual(EngineHarness.allHarnessTokens, Set(try fileTokens()))
    }

    // Uniqueness is load-bearing: a new producer cannot reuse an existing token.
    func test_tokens_areUnique() throws {
        let flat = producerTokens
        XCTAssertEqual(flat.count, Set(flat).count, "a producer reuses an existing token")
        let file = try fileTokens()
        XCTAssertEqual(file.count, Set(file).count, "harness-safe-stages.txt has a duplicate")
    }

    // The runtime registry is the GATE: the append refuses a token outside it,
    // writing nothing (which becomes annotation_failed, not a silent drop).
    func test_append_failsClosed_onUnregisteredToken() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("reg-\(UUID().uuidString).log")
        try Data("{}\n".utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let before = try Data(contentsOf: log)
        let ok = EngineHarness.appendHarnessTokens(
            [(level: "INFO", token: "harness_case.status_only"),
             (level: "WARN", token: "harness_totally_unregistered_token"),
             (level: "INFO", token: "harness_initiate.ok")],
            to: log
        )
        XCTAssertFalse(ok, "append must refuse an unregistered token")
        XCTAssertEqual(try Data(contentsOf: log), before, "nothing may be written on refusal")
    }
}
