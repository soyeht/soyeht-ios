import Testing
import Foundation
@testable import SoyehtCore

/// Pins the iOS side of the theyos PR #88 installability contract.
///
/// The backend catalog now carries `installable` (always present on #88+
/// engines), plus `unavailable_reason_code` / `unavailable_reason` (omitted
/// when installable). `Claw.installability` is the single source of truth the
/// UI gates on — these tests lock the decode + the fail-open compat rule so a
/// future change cannot silently re-open the "Install button on a
/// non-installable claw" bug.
@Suite struct ClawInstallabilityTests {

    /// Mirrors `SoyehtAPIClient.decoder` — the catalog is decoded with
    /// `.convertFromSnakeCase`, so `unavailable_reason_code` lands as
    /// `unavailableReasonCode` before key lookup. If the client strategy ever
    /// diverges from this, these tests are wrong and must be revisited.
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Minimal but valid `availability` payload (required, non-optional on
    /// `Claw`). Installability is orthogonal to this dynamic projection.
    private let availabilityJSON = """
    {"name":"%NAME%","install":{"status":"not_installed","progress":null,"installed_at":null,"error":null,"job_id":null},"host":{"cold_path_ready":true,"has_golden":true,"has_base_rootfs":true,"maintenance_blocked":false,"maintenance_retry_after_secs":null},"overall":{"state":"not_installed"},"reasons":[{"type":"not_installed"}],"degradations":[]}
    """

    private func clawJSON(name: String, fields: String) -> Data {
        let avail = availabilityJSON.replacingOccurrences(of: "%NAME%", with: name)
        return Data("""
        {"data":[{"name":"\(name)","description":"d","language":"go","buildable":false,"availability":\(avail)\(fields)}]}
        """.utf8)
    }

    private func decodeSingle(name: String, fields: String) throws -> Claw {
        let response = try decoder().decode(ClawsResponse.self, from: clawJSON(name: name, fields: fields))
        return try #require(response.data.first)
    }

    @Test("installable:false + catalog_only decodes to .unavailable with reason code and message")
    func nonInstallableCatalogOnly() throws {
        let claw = try decodeSingle(
            name: "claude-claw",
            fields: ",\"installable\":false,\"unavailable_reason_code\":\"catalog_only\",\"unavailable_reason\":\"Claude Code plugin, not a server daemon\""
        )
        #expect(claw.installable == false)
        #expect(claw.unavailableReasonCode == .catalogOnly)  // pins .convertFromSnakeCase mapping
        #expect(
            claw.installability == .unavailable(
                reasonCode: .catalogOnly,
                message: "Claude Code plugin, not a server daemon"
            )
        )
        #expect(claw.installability.isInstallable == false)
    }

    @Test("detected_unverified decodes to .detectedUnverified")
    func nonInstallableDetectedUnverified() throws {
        let claw = try decodeSingle(
            name: "someclaw",
            fields: ",\"installable\":false,\"unavailable_reason_code\":\"detected_unverified\""
        )
        #expect(claw.unavailableReasonCode == .detectedUnverified)
        #expect(claw.installability == .unavailable(reasonCode: .detectedUnverified, message: nil))
    }

    @Test("legacy catalog WITHOUT installability fields fails open to .installable")
    func legacyEngineFailsOpen() throws {
        // A pre-#88 engine omits all three keys. Decode must not break, and
        // the claw must be treated as installable (legacy behavior preserved;
        // the backend install handler remains the backstop).
        let claw = try decodeSingle(name: "picoclaw", fields: "")
        #expect(claw.installable == nil)
        #expect(claw.unavailableReasonCode == nil)
        #expect(claw.installability == .installable)
        #expect(claw.installability.isInstallable)
    }

    @Test("unknown reason code does not break decode and resolves to .unknown")
    func unknownReasonCodeIsSoft() throws {
        let claw = try decodeSingle(
            name: "futureclaw",
            fields: ",\"installable\":false,\"unavailable_reason_code\":\"some_future_reason\",\"unavailable_reason\":\"new backend reason\""
        )
        #expect(claw.unavailableReasonCode == .unknown)
        #expect(
            claw.installability == .unavailable(reasonCode: .unknown, message: "new backend reason")
        )
    }

    @Test("installable:true decodes to .installable with no reason payload")
    func installableTrue() throws {
        let claw = try decodeSingle(name: "openclaw", fields: ",\"installable\":true")
        #expect(claw.installable == true)
        #expect(claw.unavailableReasonCode == nil)
        #expect(claw.installability == .installable)
    }

    @Test("UnavailableReasonCode round-trips snake_case wire values")
    func reasonCodeRawValues() {
        #expect(ClawUnavailableReasonCode.catalogOnly.rawValue == "catalog_only")
        #expect(ClawUnavailableReasonCode.detectedUnverified.rawValue == "detected_unverified")
        #expect(ClawUnavailableReasonCode.noInstallPlan.rawValue == "no_install_plan")
        #expect(ClawUnavailableReasonCode(rawValue: "unrecognized") == nil)
    }
}
