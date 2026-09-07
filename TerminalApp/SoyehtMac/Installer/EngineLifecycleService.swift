import CryptoKit
import Darwin
import Foundation
import os
import SoyehtCore

/// Production adapter for a bounded replacement round. Run on a worker, never
/// on the main thread. Legacy removal requires explicit consent bound to the
/// observed process and target. Subsequent replacements preserve the PTY owner.
enum EngineLifecycleService {
    typealias Coordinator = EngineReplacementCoordinator

    struct MigrationConsent: Sendable {
        let original: LegacyEngineObservation
        let target: EngineArtifactIdentity
    }

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "engine-lifecycle")

    static func run(resume: Bool, consent: MigrationConsent? = nil) -> Coordinator.Outcome {
        logger.notice("engine.lifecycle.begin resume=\(resume) consent=\(consent != nil)")
        let outcome = performRound(resume: resume, consent: consent)
        // Never stringify the associated observations: they include machine
        // paths and process identities. Only closed outcome/reason names log.
        let name: String
        var reason = "none"
        switch outcome {
        case .readyWithContinuity: name = "readyWithContinuity"
        case .readyNoReplacement: name = "readyNoReplacement"
        case .readyAfterSupervisorRestart: name = "readyAfterSupervisorRestart"
        case .readyAfterLegacyMigration: name = "readyAfterLegacyMigration"
        case .legacyMigrationRequired: name = "legacyMigrationRequired"
        case .unconfirmed(let value): name = "unconfirmed"; reason = String(describing: value)
        }
        logger.notice("engine.lifecycle.result outcome=\(name, privacy: .public) reason=\(reason, privacy: .public)")
        return outcome
    }

    private static func performRound(resume: Bool, consent: MigrationConsent?) -> Coordinator.Outcome {
        let profile = SoyehtInstallProfile.current
        let support = EnginePackager.soyehtSupportDirectory
        let installation = PTYSupervisorInstallation(profile: profile, home: FileManager.default.homeDirectoryForCurrentUser)
        let enginePlist = EngineBackgroundAgent.installedPlistURL(label: profile.engineLaunchdLabel)
        let runner: (URL, [String], TimeInterval) throws -> EngineCommandRunner.Result = {
            try EngineCommandRunner.runBlocking(executable: $0, arguments: $1, timeout: $2)
        }
        let probe = EngineInstallationProbe(supervisor: installation, enginePlist: enginePlist,
            expectedEngineProgram: "/bin/zsh", uid: getuid(), run: runner,
            readRuntime: { EngineRuntimeReadback.read(profile: profile, tokenURL: EnginePackager.bootstrapTokenURL) })

        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            // Shared CREATE leases and all other replacement processes use
            // this exact lock. It spans preparation, commands and readback.
            let journal = try EngineReplacementJournal(directory: EngineReplacementJournal.directory(in: support), profile: profile.kind)
            if resume { try journal.recoverInterruptedWrite() }
            if try journal.read() == nil {
                let artifact = try EnginePackager.validatedBundledArtifact()
                let before = probe.observe()
                let priorPID: UInt32?
                let priorBoot: String?
                let priorBroker: UUID?
                var authorizedLegacy: LegacyEngineObservation?
                switch before.engine {
                case .absent:
                    priorPID = nil
                    priorBoot = nil
                    if case .verified(let owner) = before.supervisor { priorBroker = owner.brokerBootID }
                    else { priorBroker = nil }
                case .legacy(let legacy):
                    guard consent?.original == legacy, consent?.target == artifact else {
                        return .legacyMigrationRequired(legacy, artifact)
                    }
                    priorPID = nil
                    priorBoot = nil
                    priorBroker = nil
                    authorizedLegacy = legacy
                case .present(let runtime, let targetMatches):
                    if targetMatches, case .verified(let owner) = before.supervisor,
                       runtime.matchesSupervisedInstallation(expected: artifact, supervisor: owner) {
                        return .readyNoReplacement
                    }
                    // Counting zero legacy PTYs cannot close that engine's
                    // remote CREATE admission. Do not infer migration consent.
                    guard runtime.terminalBackend == "supervisor",
                          let pid = runtime.processID, let boot = runtime.processBootID,
                          case let .verified(owner) = before.supervisor,
                          owner.protocolVersion == artifact.ptySupervisorProtocol,
                          runtime.terminalSupervisorBootID == owner.brokerBootID else {
                        return .unconfirmed(.removalPreconditionUnavailable)
                    }
                    priorPID = pid
                    priorBoot = boot
                    priorBroker = owner.brokerBootID
                case .unknown: return .unconfirmed(.observationUnavailable)
                }
                if case .incompatible = before.supervisor { return .unconfirmed(.supervisorIncompatible) }
                if case .verified(let owner) = before.supervisor,
                   owner.protocolVersion != artifact.ptySupervisorProtocol {
                    return .unconfirmed(.supervisorIncompatible)
                }
                // Do not overwrite even the helper file of a daemon whose
                // compatibility is unknown. Absence is proved before staging
                // and independently revalidated by ensure() before loading.
                if case .unknown = before.supervisor,
                   !PTYSupervisorInstaller.positivelyAbsent(installation: installation, run: runner) {
                    return .unconfirmed(.observationUnavailable)
                }
                logger.notice("engine.lifecycle.stage stage=package_staging")
                try EnginePackager.stage(holding: journal)
                let owner: PTYSupervisorStatus
                switch PTYSupervisorInstaller.ensure(installation: installation, protocolVersion: artifact.ptySupervisorProtocol) {
                case .ready(let value): owner = value
                case .incompatible: return .unconfirmed(.supervisorIncompatible)
                case .unconfirmed: return .unconfirmed(.observationUnavailable)
                }
                logger.notice("engine.lifecycle.stage stage=supervisor_verified")
                let plist = try preparedPlist(profile: profile, supervisor: installation)
                let record = EngineReplacementJournal.Record(formatVersion: 2, operationID: UUID(), profileKind: profile.kind.rawValue,
                    expectedArtifact: artifact, plistDigest: digest(plist), priorEnginePID: priorPID,
                    priorEngineBootID: priorBoot, priorBrokerBootID: priorBroker ?? owner.brokerBootID, phase: .prepared,
                    authorizedLegacyRemoval: authorizedLegacy)
                // Finish preparation before committing its digest. No engine
                // removal/load is allowed until the journal save succeeds.
                try FileManager.default.createDirectory(at: enginePlist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try plist.write(to: enginePlist, options: .atomic)
                try journal.save(record)
            }

            if let pending = try journal.read(), pending.authorizedLegacyRemoval != nil,
               pending.phase == .prepared || pending.phase == .removalUncertain,
               case .legacy(let current) = probe.observeEngine(), current != pending.authorizedLegacyRemoval {
                guard consent?.original == current, consent?.target == pending.expectedArtifact else {
                    return .legacyMigrationRequired(current, pending.expectedArtifact)
                }
                try journal.renewLegacyConsent(expected: pending, observed: current)
            }

            let coordinator = Coordinator(journal: journal, operations: .init(
                acquireCreationPermit: {
                    // The journal's exclusive flock is already held; CREATE
                    // cannot acquire its shared lease until this round ends.
                    .init(finish: { _ in })
                },
                validatePreparedTarget: { record in
                    guard try EnginePackager.validatedArtifact(in: EnginePackager.engineDestinationDirectory) == record.expectedArtifact,
                          try digest(Data(contentsOf: enginePlist)) == record.plistDigest else {
                        throw PreparationFailure.changedTarget
                    }
                },
                observe: { probe.observe() },
                validateRemoval: { record, observed in
                    if case .legacy(let legacy) = observed {
                        guard record.authorizedLegacyRemoval == legacy,
                              case .legacy(let current) = probe.observeEngine(), current == legacy else {
                            throw PreparationFailure.unverifiedOwner
                        }
                        return
                    }
                    guard case .present(let runtime, _) = observed,
                          runtime.terminalBackend == "supervisor",
                          runtime.processID == record.priorEnginePID,
                          runtime.processBootID == record.priorEngineBootID,
                          case let .verified(owner) = probe.observeSupervisor(),
                          owner.protocolVersion == record.expectedArtifact.ptySupervisorProtocol,
                          runtime.terminalSupervisorBootID == owner.brokerBootID else {
                        throw PreparationFailure.unverifiedOwner
                    }
                },
                removeEngine: { observed in
                    // Another domain or incarnation is never removed.
                    guard let domain = probe.removalDomain(for: observed) else { return }
                    _ = try? runner(URL(fileURLWithPath: "/bin/launchctl"),
                        ["bootout", "\(domain)/\(getuid())/\(profile.engineLaunchdLabel)"], 5)
                },
                loadPreparedEngine: {
                    _ = try? runner(URL(fileURLWithPath: "/bin/launchctl"), ["load", "-S", "Background", enginePlist.path], 5)
                },
                waitBeforeObservation: { Thread.sleep(forTimeInterval: 0.2) }
            ))
            return coordinator.run()
        } catch let error as EngineReplacementJournal.Failure {
            logger.error("engine.lifecycle.journal_unavailable cause=\(String(describing: error), privacy: .public)")
            return .unconfirmed(.journalUnavailable)
        } catch {
            return .unconfirmed(.preparationUnavailable)
        }
    }

    private enum PreparationFailure: Error { case changedTarget, unverifiedOwner, invalidPlist }

    private static func preparedPlist(profile: SoyehtInstallProfile, supervisor: PTYSupervisorInstallation) throws -> Data {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(profile.engineLaunchAgentPlistName)")
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any],
              plist["Label"] as? String == profile.engineLaunchdLabel else { throw PreparationFailure.invalidPlist }
        var environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        environment["THEYOS_PTY_SUPERVISOR_SOCKET"] = supervisor.socket.path
        plist["EnvironmentVariables"] = environment
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
