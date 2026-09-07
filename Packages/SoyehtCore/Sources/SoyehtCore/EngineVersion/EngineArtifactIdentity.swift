import Foundation

/// Linked executable identity. UUID equality is neither signature validation
/// nor permission to restart a service; session ownership is a separate check.
public struct EngineArtifactIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let gitSHA: String
    public let imageUUID: String?
    public let ptySupervisorProtocol: UInt16

    enum CodingKeys: String, CodingKey {
        case version
        case gitSHA = "git_sha"
        case imageUUID = "image_uuid"
        case ptySupervisorProtocol = "pty_supervisor_protocol"
    }

    public enum Comparison: Equatable, Sendable {
        case sameImage, differentImage, unknown
    }

    public func compareImage(to other: Self) -> Comparison {
        guard let lhs = validImageUUID, let rhs = other.validImageUUID else { return .unknown }
        return lhs == rhs ? .sameImage : .differentImage
    }

    private var validImageUUID: String? {
        guard let imageUUID, imageUUID.utf8.count == 32,
              imageUUID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return imageUUID
    }
}

/// Output of the read-only ptyd status command. Absence or failed decoding
/// must not be substituted with an empty inventory by the caller.
public struct PTYSupervisorStatus: Decodable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let brokerBootID: UUID
    public let brokerPID: UInt32?
    public let liveSessions: UInt

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case brokerBootID = "broker_boot_id"
        case brokerPID = "broker_pid"
        case liveSessions = "live_sessions"
    }
}

public struct EngineRuntimeIdentity: Decodable, Sendable {
    public let version: String?
    public let updateAvailable: Bool?
    public let artifact: EngineArtifactIdentity?
    public let terminalBackend: String?
    public let terminalSupervisorBootID: UUID?
    public let processID: UInt32?
    public let processBootID: String?

    enum CodingKeys: String, CodingKey {
        case version
        case artifact
        case terminalBackend = "terminal_backend"
        case updateAvailable = "update_available"
        case terminalSupervisorBootID = "terminal_supervisor_boot_id"
        case processID = "process_id"
        case processBootID = "process_boot_id"
    }

    /// A successful legacy version response is distinct from an unavailable
    /// response. It describes an API generation, not a process identity.
    public var isLegacyResponse: Bool {
        if terminalBackend == "legacy" { return true }
        guard artifact == nil, terminalBackend == nil, processID == nil,
              processBootID == nil, terminalSupervisorBootID == nil,
              let version else { return false }
        // Published engines report this exact legacy response while their
        // version cache is empty. It identifies the response contract only;
        // migration still requires independent kernel/job identity and consent.
        if version == "unknown", updateAvailable != nil { return true }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { UInt($0) != nil }
    }

    public enum ReplacementOutcome: Equatable, Sendable {
        case readyWithContinuity
        /// The caller revalidated the installation, but its supervisor restarted.
        /// Old PTYs are not claimed to survive.
        case readyAfterSupervisorRestart
        case unconfirmed
    }

    /// Final readback after the caller validates the installation namespace.
    /// Matching semver, path or git SHA
    /// alone cannot confirm it. The prior broker identity is captured before
    /// the engine stops, not taken from this final observation.
    public func supervisedReplacementOutcome(
        expected: EngineArtifactIdentity,
        priorBrokerBootID: UUID,
        supervisor: PTYSupervisorStatus
    ) -> ReplacementOutcome {
        guard matchesSupervisedInstallation(expected: expected, supervisor: supervisor) else { return .unconfirmed }
        return supervisor.brokerBootID == priorBrokerBootID ? .readyWithContinuity : .readyAfterSupervisorRestart
    }

    /// Current readiness only. Without an earlier observation this says
    /// nothing about session continuity across an interval.
    public func matchesSupervisedInstallation(expected: EngineArtifactIdentity, supervisor: PTYSupervisorStatus) -> Bool {
        guard let artifact,
              expected.compareImage(to: artifact) == .sameImage,
              terminalBackend == "supervisor",
              terminalSupervisorBootID == supervisor.brokerBootID,
              artifact.ptySupervisorProtocol == expected.ptySupervisorProtocol,
              supervisor.protocolVersion == expected.ptySupervisorProtocol else { return false }
        return true
    }

}

extension SoyehtAPIClient {
    public func engineRuntimeIdentity(context: ServerContext) async throws -> EngineRuntimeIdentity {
        var request = URLRequest(url: try buildURL(host: context.host, path: "/api/v1/version"))
        request.timeoutInterval = 5
        context.server.kind.applyAuth(to: &request, token: context.token)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(EngineRuntimeIdentity.self, from: data)
    }
}
