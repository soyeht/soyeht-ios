import XCTest
@testable import SoyehtMacDomain

/// Migration coverage for the Fase 4 reshape of `AgentType` from a fixed
/// four-case enum to `.shell | .claw(String)`.
///
/// The on-disk representation did NOT get a version bump — the custom
/// Codable maps the old rawValue strings (`"claude"`, `"codex"`, …) onto
/// `.claw(raw)` and `"shell"` onto `.shell`, so v3 `Conversation` payloads
/// must still decode. These tests pin that contract so the collapse never
/// regresses.
final class AgentTypeMigrationTests: XCTestCase {

    // MARK: - Decode

    func test_decode_shell_maps_to_shell_case() throws {
        let data = Data("\"shell\"".utf8)
        let decoded = try JSONDecoder().decode(AgentType.self, from: data)
        XCTAssertEqual(decoded, .shell)
    }

    func test_decode_legacy_claude_maps_to_claw_case() throws {
        let data = Data("\"claude\"".utf8)
        let decoded = try JSONDecoder().decode(AgentType.self, from: data)
        XCTAssertEqual(decoded, .claw("claude"))
    }

    func test_decode_legacy_codex_maps_to_claw_case() throws {
        let data = Data("\"codex\"".utf8)
        let decoded = try JSONDecoder().decode(AgentType.self, from: data)
        XCTAssertEqual(decoded, .claw("codex"))
    }

    func test_decode_legacy_hermes_maps_to_claw_case() throws {
        let data = Data("\"hermes\"".utf8)
        let decoded = try JSONDecoder().decode(AgentType.self, from: data)
        XCTAssertEqual(decoded, .claw("hermes"))
    }

    func test_decode_unknown_claw_name_is_preserved() throws {
        let data = Data("\"picoclaw\"".utf8)
        let decoded = try JSONDecoder().decode(AgentType.self, from: data)
        XCTAssertEqual(decoded, .claw("picoclaw"))
    }

    // MARK: - Encode

    func test_encode_shell_writes_raw_shell_string() throws {
        let json = try JSONEncoder().encode(AgentType.shell)
        XCTAssertEqual(String(data: json, encoding: .utf8), "\"shell\"")
    }

    func test_encode_claw_writes_raw_name_string() throws {
        let json = try JSONEncoder().encode(AgentType.claw("claude"))
        XCTAssertEqual(String(data: json, encoding: .utf8), "\"claude\"")
    }

    // MARK: - Round-trip

    func test_roundtrip_preserves_identity_for_every_canonical_case() throws {
        for agent in AgentType.canonicalCases {
            let data = try JSONEncoder().encode(agent)
            let back = try JSONDecoder().decode(AgentType.self, from: data)
            XCTAssertEqual(back, agent, "round-trip failed for \(agent)")
        }
    }

    // MARK: - Display helpers

    func test_displayName_mirrors_raw_value() {
        XCTAssertEqual(AgentType.shell.displayName, "shell")
        XCTAssertEqual(AgentType.claw("claude").displayName, "claude")
        XCTAssertEqual(AgentType.claw("picoclaw").displayName, "picoclaw")
    }

    func test_rawValue_mirrors_display_name() {
        XCTAssertEqual(AgentType.shell.rawValue, "shell")
        XCTAssertEqual(AgentType.claw("codex").rawValue, "codex")
    }
}
