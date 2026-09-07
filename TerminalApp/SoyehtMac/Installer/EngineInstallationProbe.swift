import Foundation
import SoyehtCore

/// Read-only adapter for one prepared installation. All commands and runtime
/// requests are bounded by their adapters and execute off the main thread.
/// Neither failed probes nor PID races authorize installing another daemon.
struct EngineInstallationProbe {
    let supervisor: PTYSupervisorInstallation
    let enginePlist: URL
    let expectedEngineProgram: String
    let uid: UInt32
    let run: (URL, [String], TimeInterval) throws -> EngineCommandRunner.Result
    let readRuntime: () -> EngineRuntimeIdentity?

    func observe() -> EngineReplacementCoordinator.Observation {
        let owner = observeSupervisor()
        return .init(engine: observeEngine(), supervisor: owner)
    }

    func observeSupervisor() -> EngineReplacementCoordinator.SupervisorObservation {
        let first: PTYSupervisorStatus
        switch readSupervisorStatus() {
        case let .success(value): first = value
        case .failure(.incompatible): return .incompatible
        case .failure(.unknown): return .unknown
        }
        let result = command("user", supervisor.label)
        guard result.status == 0,
              supervisor.matchesLoadedJob(result.output, uid: uid, status: first),
              case let .success(second) = readSupervisorStatus(),
              first.brokerBootID == second.brokerBootID,
              first.brokerPID == second.brokerPID else { return .unknown }
        return .verified(second)
    }

    private enum ProbeFailure: Error { case unknown, incompatible }
    private struct ErrorReply: Decodable { let error: String }

    private func readSupervisorStatus() -> Result<PTYSupervisorStatus, ProbeFailure> {
        guard let result = try? run(supervisor.executable, ["--status", "--socket", supervisor.socket.path], 12),
              !result.timedOut, !result.outputTruncated else { return .failure(.unknown) }
        if result.status == 2,
           let reply = try? JSONDecoder().decode(ErrorReply.self, from: result.output),
           reply.error == "protocol_incompatible" { return .failure(.incompatible) }
        guard result.succeeded,
              let status = try? JSONDecoder().decode(PTYSupervisorStatus.self, from: result.output) else { return .failure(.unknown) }
        return .success(status)
    }

    private func observeEngine() -> EngineReplacementCoordinator.EngineObservation {
        let label = supervisor.profile.engineLaunchdLabel
        let user = command("user", label)
        let gui = command("gui", label)
        let userPresence = EngineBackgroundAgent.classifyPresence(user, domain: "user", label: label, uid: uid)
        let guiPresence = EngineBackgroundAgent.classifyPresence(gui, domain: "gui", label: label, uid: uid)
        if userPresence == .absent && guiPresence == .absent { return .absent }
        guard userPresence != .unknown, guiPresence != .unknown else { return .unknown }
        // Two jobs can be alive during an interrupted domain migration. Do not
        // choose one and attribute the other's HTTP response to it.
        guard (userPresence == .present) != (guiPresence == .present) else { return .unknown }
        let domain = userPresence == .present ? "user" : "gui"
        let result = domain == "user" ? user : gui
        guard let first = LaunchdJobSnapshot(output: result.output, domain: domain, label: label, uid: uid),
              let firstPID = first.pid,
              let runtime = readRuntime(), runtime.processID == firstPID else { return .unknown }
        let after = command(domain, label)
        guard after.status == 0,
              let second = LaunchdJobSnapshot(output: after.output, domain: domain, label: label, uid: uid),
              second == first else { return .unknown }
        return .present(runtime, targetConfigurationMatches: domain == "user"
            && first.path == enginePlist.path && first.program == expectedEngineProgram)
    }

    private func command(_ domain: String, _ label: String) -> EngineBackgroundAgent.Result {
        guard let result = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "\(domain)/\(uid)/\(label)"], 5),
              !result.timedOut, !result.outputTruncated else { return .init(status: -1, output: "") }
        return .init(status: result.status, output: String(decoding: result.output, as: UTF8.self))
    }
}
