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
    var readProcess: (UInt32, UInt32) -> EngineProcessIncarnation? = { EngineProcessIncarnation.read(pid: $0, uid: $1) }

    func observe() -> EngineReplacementCoordinator.Observation {
        let owner = observeSupervisor()
        return .init(engine: observeEngine(), supervisor: owner)
    }

    func observeSupervisor() -> EngineReplacementCoordinator.SupervisorObservation {
        PTYSupervisorProbe(supervisor: supervisor, uid: uid, run: run).observe()
    }

    func observeEngine() -> EngineReplacementCoordinator.EngineObservation {
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
              let firstPID = first.pid else { return .unknown }
        let incarnation = readProcess(firstPID, uid)
        guard let runtime = readRuntime() else { return .unknown }
        let after = command(domain, label)
        guard after.status == 0,
              let second = LaunchdJobSnapshot(output: after.output, domain: domain, label: label, uid: uid),
              second == first else { return .unknown }
        if runtime.isLegacyResponse {
            guard let incarnation, readProcess(firstPID, uid) == incarnation,
                  runtime.processID == nil || runtime.processID == firstPID else { return .unknown }
            let legacy = LegacyEngineObservation(process: incarnation, domain: domain, job: first)
            return legacy.isValid(profile: supervisor.profile) ? .legacy(legacy) : .unknown
        }
        guard runtime.processID == firstPID else { return .unknown }
        return .present(runtime, targetConfigurationMatches: domain == "user"
            && first.path == enginePlist.path && first.program == expectedEngineProgram)
    }

    func removalDomain(for expected: EngineReplacementCoordinator.EngineObservation) -> String? {
        let pid: UInt32
        switch (expected, observeEngine()) {
        case let (.legacy(wanted), .legacy(actual)) where wanted == actual:
            return actual.domain
        case let (.present(wanted, _), .present(actual, _))
            where wanted.processID == actual.processID && wanted.processBootID == actual.processBootID:
            guard let value = actual.processID else { return nil }
            pid = value
        default: return nil
        }
        let label = supervisor.profile.engineLaunchdLabel
        for domain in ["user", "gui"] {
            let value = command(domain, label)
            if value.status == 0,
               let job = LaunchdJobSnapshot(output: value.output, domain: domain, label: label, uid: uid),
               job.pid == pid, job.program == expectedEngineProgram,
               supervisor.profile.ownsEngineCommand(job.arguments.joined(separator: " ")) { return domain }
        }
        return nil
    }

    private func command(_ domain: String, _ label: String) -> EngineBackgroundAgent.Result {
        guard let result = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "\(domain)/\(uid)/\(label)"], 5),
              !result.timedOut, !result.outputTruncated else { return .init(status: -1, output: "") }
        return .init(status: result.status, output: String(decoding: result.output, as: UTF8.self))
    }
}

/// Supervisor-only inspection has no engine program or HTTP dependencies.
/// Another compatible linked image is deliberate: restarting a live PTY owner
/// to match the package image would destroy the sessions being preserved.
struct PTYSupervisorProbe {
    let supervisor: PTYSupervisorInstallation
    let uid: UInt32
    let run: (URL, [String], TimeInterval) throws -> EngineCommandRunner.Result

    func observe() -> EngineReplacementCoordinator.SupervisorObservation {
        let first: PTYSupervisorStatus
        switch readSupervisorStatus() {
        case let .success(value): first = value
        case .failure(.incompatible): return .incompatible
        case .failure(.unknown): return .unknown
        }
        let result: EngineCommandRunner.Result
        do { result = try run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "user/\(uid)/\(supervisor.label)"], 5) }
        catch { return .unknown }
        guard result.succeeded,
              supervisor.matchesLoadedJob(String(decoding: result.output, as: UTF8.self), uid: uid, status: first),
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

}
