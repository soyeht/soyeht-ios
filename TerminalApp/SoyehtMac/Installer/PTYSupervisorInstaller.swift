import Foundation
import Darwin
import SoyehtCore

/// Installs only a positively absent supervisor. There is deliberately no
/// restart, bootout or replacement operation in this component's interface.
enum PTYSupervisorInstaller {
    enum Outcome {
        case ready(PTYSupervisorStatus)
        case incompatible
        case unconfirmed
    }

    struct Operations {
        var observe: () -> EngineReplacementCoordinator.SupervisorObservation
        var isAbsent: () -> Bool
        var prepare: () throws -> Void
        var load: () -> Void
        var wait: () -> Void
    }

    static func ensure(protocolVersion: UInt16, operations: Operations, observationLimit: Int = 6) -> Outcome {
        switch operations.observe() {
        case .verified(let status):
            return status.protocolVersion == protocolVersion ? .ready(status) : .incompatible
        case .incompatible: return .incompatible
        case .unknown: break
        }
        guard operations.isAbsent() else { return .unconfirmed }
        do { try operations.prepare() }
        catch { return .unconfirmed }
        // Preparation can take time. Revalidate absence immediately before
        // load; another installer or launchd may have started the daemon.
        guard operations.isAbsent() else {
            if case .verified(let status) = operations.observe(), status.protocolVersion == protocolVersion {
                return .ready(status)
            }
            return .unconfirmed
        }
        operations.load()
        for attempt in 0..<max(1, observationLimit) {
            if attempt > 0 { operations.wait() }
            switch operations.observe() {
            case .verified(let status):
                return status.protocolVersion == protocolVersion ? .ready(status) : .incompatible
            case .incompatible: return .incompatible
            case .unknown: continue
            }
        }
        return .unconfirmed
    }

    /// The caller holds the profile's lifecycle journal lock and has already
    /// staged/verified the helper. Executes off the main thread.
    static func ensure(installation: PTYSupervisorInstallation, protocolVersion: UInt16) -> Outcome {
        let runner: (URL, [String], TimeInterval) throws -> EngineCommandRunner.Result = {
            try EngineCommandRunner.runBlocking(executable: $0, arguments: $1, timeout: $2)
        }
        let probe = EngineInstallationProbe(supervisor: installation,
                                            enginePlist: EngineBackgroundAgent.installedPlistURL(label: installation.profile.engineLaunchdLabel, home: installation.home),
                                            expectedEngineProgram: "/bin/zsh", uid: getuid(), run: runner,
                                            readRuntime: { nil })
        return ensure(protocolVersion: protocolVersion, operations: .init(
            observe: { probe.observeSupervisor() },
            isAbsent: {
                for domain in ["user", "gui"] {
                    guard let result = try? runner(URL(fileURLWithPath: "/bin/launchctl"),
                                                   ["print", "\(domain)/\(getuid())/\(installation.label)"], 5),
                          !result.timedOut, !result.outputTruncated,
                          EngineBackgroundAgent.classifyPresence(
                            .init(status: result.status, output: String(decoding: result.output, as: UTF8.self)),
                            domain: domain, label: installation.label, uid: getuid()) == .absent else { return false }
                }
                var info = stat()
                return lstat(installation.socket.path, &info) != 0 && errno == ENOENT
            },
            prepare: {
                struct Contract: Decodable { let protocol_version: UInt16 }
                let contract = try runner(installation.executable, ["--contract"], 5)
                guard contract.succeeded,
                      try JSONDecoder().decode(Contract.self, from: contract.output).protocol_version == protocolVersion else {
                    throw PreparationFailure.invalidHelper
                }
                let plist = try installation.plistData()
                for directory in [installation.root, installation.state] {
                    if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw PreparationFailure.unavailable }
                    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw PreparationFailure.unavailable }
                    var info = stat()
                    let valid = fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
                    Darwin.close(fd)
                    guard valid else { throw PreparationFailure.unavailable }
                }
                try FileManager.default.createDirectory(at: installation.log.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: installation.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try plist.write(to: installation.plist, options: .atomic)
            },
            load: { _ = try? runner(URL(fileURLWithPath: "/bin/launchctl"), ["load", "-S", "Background", installation.plist.path], 5) },
            wait: { Thread.sleep(forTimeInterval: 0.2) }
        ))
    }

    private enum PreparationFailure: Error { case invalidHelper, unavailable }
}
