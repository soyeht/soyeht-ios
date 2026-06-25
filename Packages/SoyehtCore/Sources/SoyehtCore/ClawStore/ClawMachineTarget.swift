import Foundation

/// Platform-neutral target for Claw Store operations.
///
/// UI layers should resolve a user-selected machine into one of these values
/// before constructing view models. The wire-level API clients still speak
/// `ClawAPITarget` / `CreateInstanceTarget`; this type is the shared boundary
/// that keeps iOS and macOS from inventing parallel target vocabularies.
public enum ClawMachineTarget: Sendable, Equatable {
    /// Bearer/Cookie-authenticated paired server context.
    case server(ServerContext)

    /// PoP-signed household Claw routes served by one selected Mac engine.
    case householdEndpoint(serverID: String, endpoint: URL)

    /// The selected machine cannot be reached by any supported Claw Store
    /// transport.
    case unavailable(MissingReason)

    public enum MissingReason: Sendable, Equatable {
        case unknownServer
        case missingContext
        case macUnreachable
    }

    public var serverID: String? {
        switch self {
        case .server(let context):
            return context.serverId
        case .householdEndpoint(let serverID, _):
            return serverID
        case .unavailable:
            return nil
        }
    }

    public var apiTarget: ClawAPITarget? {
        switch self {
        case .server(let context):
            return .server(context)
        case .householdEndpoint(_, let endpoint):
            return .householdEndpoint(endpoint)
        case .unavailable:
            return nil
        }
    }

    public var createInstanceTarget: CreateInstanceTarget? {
        switch self {
        case .server(let context):
            return .server(context)
        case .householdEndpoint(_, let endpoint):
            return .householdEndpoint(endpoint)
        case .unavailable:
            return nil
        }
    }

    public var supportsDeploy: Bool {
        createInstanceTarget != nil
    }
}
