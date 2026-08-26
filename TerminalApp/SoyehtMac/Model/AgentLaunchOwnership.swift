import Darwin
import Foundation
import SoyehtCore

@_silgen_name("proc_pidinfo")
private func soyeht_agent_runtime_proc_pidinfo(
    _ pid: pid_t,
    _ flavor: Int32,
    _ arg: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32

protocol AgentLaunchOwnershipPersisting {
    @discardableResult
    func save(nonce: String, for paneID: Conversation.ID) -> Bool
    func loadNonce(for paneID: Conversation.ID) -> String?
}

struct AgentLaunchOwnershipKeychainStore: AgentLaunchOwnershipPersisting {
    private let keychain = KeychainHelper(
        service: SoyehtInstallProfile.current.keychainService + ".agent-launch-ownership"
    )

    private func account(for paneID: Conversation.ID) -> String {
        "pane.\(paneID.uuidString.lowercased())"
    }

    @discardableResult
    func save(nonce: String, for paneID: Conversation.ID) -> Bool {
        keychain.saveString(nonce, account: account(for: paneID))
    }

    func loadNonce(for paneID: Conversation.ID) -> String? {
        keychain.loadString(account: account(for: paneID))
    }
}

/// Keeps launch possession out of the workspace snapshot. The environment of
/// the owning process and this profile-scoped Keychain row are the only durable
/// copies; public pane metadata is never itself an authentication credential.
final class AgentLaunchOwnershipRegistry {
    private static let revokedMarker = "soyeht.revoked-launch-ownership.v1"
    private let persistence: AgentLaunchOwnershipPersisting
    private var expectedByPane: [Conversation.ID: String] = [:]

    init(persistence: AgentLaunchOwnershipPersisting = AgentLaunchOwnershipKeychainStore()) {
        self.persistence = persistence
    }

    @discardableResult
    func prepareForLaunch(paneID: Conversation.ID) -> Bool {
        // Never replace a live process unless its old bearer has first been
        // durably tombstoned. Deletion is not a safe fallback: a Developer-ID
        // build may use the login Keychain when the Data Protection Keychain
        // entitlement is unavailable, and deleting only one namespace could
        // make an old bearer valid again after relaunch.
        guard persistence.save(nonce: Self.revokedMarker, for: paneID) else {
            // Keep the previous in-memory owner authoritative and let the
            // caller abort before spawning a replacement. Continuing would
            // create a split-brain where the old durable bearer can revive.
            return false
        }
        expectedByPane[paneID] = Self.revokedMarker
        return true
    }

    @discardableResult
    func register(paneID: Conversation.ID, nonce: String) -> Bool {
        guard persistence.save(nonce: nonce, for: paneID) else {
            // A memory-only bearer would work until relaunch and then strand
            // the persistent agent. More importantly, it would create two
            // authentication truths. Fail closed and retain a local tombstone.
            expectedByPane[paneID] = Self.revokedMarker
            return false
        }
        expectedByPane[paneID] = nonce
        return true
    }

    /// Restores the bearer for a process that was deliberately left alive
    /// because a destructive teardown failed before completion.
    @discardableResult
    func restore(paneID: Conversation.ID, nonce: String) -> Bool {
        register(paneID: paneID, nonce: nonce)
    }

    /// Returns legacy snapshot rows that should be scrubbed after a one-shot
    /// migration. Keychain wins when both copies exist because it is updated
    /// synchronously at launch, before the debounced workspace snapshot.
    func rehydrate(
        from conversations: [Conversation],
        trustedShellPaneIDs: Set<Conversation.ID> = []
    ) -> [Conversation.ID] {
        var migratedLegacyPaneIDs: [Conversation.ID] = []
        for conversation in conversations {
            guard case .engineLocal = conversation.commander,
                  conversation.content.isTerminal else { continue }
            let mayRestoreProtectedOwnership = !conversation.agent.isShell
                || trustedShellPaneIDs.contains(conversation.id)
            guard mayRestoreProtectedOwnership else { continue }
            if let persisted = persistence.loadNonce(for: conversation.id), !persisted.isEmpty {
                expectedByPane[conversation.id] = persisted
            } else if !conversation.agent.isShell,
                      let legacy = conversation.agentLaunchOwnershipNonce,
                      !legacy.isEmpty {
                if register(paneID: conversation.id, nonce: legacy) {
                    migratedLegacyPaneIDs.append(conversation.id)
                }
            }
        }
        return migratedLegacyPaneIDs
    }

    /// Restores a protected shell-pane nonce only after the caller has proved
    /// that the same persistent engine session survived. This deliberately
    /// does not accept a nonce supplied by an automation request.
    @discardableResult
    func rehydrateProtectedShellOwnership(paneID: Conversation.ID) -> Bool {
        guard let persisted = persistence.loadNonce(for: paneID), !persisted.isEmpty else {
            return false
        }
        expectedByPane[paneID] = persisted
        return true
    }

    /// Emergency in-process deny used when a durable tombstone cannot be
    /// written after restore has already discovered that the old process is
    /// gone. Callers must also persist non-agent pane identity so a restart
    /// cannot rehydrate the stale durable bearer.
    func quarantineInMemory(paneID: Conversation.ID) {
        expectedByPane[paneID] = Self.revokedMarker
    }

    func nonce(for paneID: Conversation.ID) -> String? {
        // Durable rows enter memory only through the early, commander-aware
        // rehydrate pass. Lazy reads could resurrect a stale row after the
        // pane's process changed ownership.
        let stored = expectedByPane[paneID]
        guard stored != Self.revokedMarker else { return nil }
        return stored
    }

    func validates(paneID: Conversation.ID, nonce: String?) -> Bool {
        guard let nonce, !nonce.isEmpty, let expected = self.nonce(for: paneID) else { return false }
        return nonce == expected
    }
}

/// Runtime identity is deliberately separate from `Conversation.agent`.
/// A pane created with the ordinary split controls remains a normal shell
/// pane (and therefore keeps its native mouse/scroll/keyboard behavior), while
/// an MCP server inherited by a manually started CLI can temporarily prove
/// which agent is active inside that shell.
struct AgentRuntimeIdentityClaim: Codable, Equatable {
    let agentName: String
    let instanceID: String
    let processID: Int32
    let processStartedAtSeconds: UInt64
    let processStartedAtMicroseconds: UInt64
    /// Parent process verified by the app when the MCP runtime claimed this
    /// pane. Reporter hooks run in (or directly under) that same CLI process,
    /// so this binds one-way reports to the concrete agent session rather than
    /// merely trusting a reusable pane nonce and agent label.
    let ownerProcessID: Int32?
    /// Kernel start time of the owner CLI process. Together with the PID this
    /// is the lifecycle identity of the agent session; a numeric PID can be
    /// recycled after the previous CLI exits.
    let ownerProcessStartedAtSeconds: UInt64?
    let ownerProcessStartedAtMicroseconds: UInt64?
    /// Kernel TTY device captured at claim time. Optional only to decode rows
    /// written before continuous TTY validation shipped. Legacy rows are
    /// decoded for migration safety but revoked instead of being upgraded from
    /// mutable live-process metadata.
    let ttyDevice: UInt32?
}

/// Pure lifecycle check for one-way hook reports. The request may sit in the
/// file spool after its CLI exits, so a matching numeric owner PID alone is
/// insufficient: macOS can recycle that PID for a later agent session.
enum AgentRuntimeReportIdentity {
    static func accepts(
        claim: AgentRuntimeIdentityClaim,
        runtimeInstanceID: String?,
        ownerProcessID: Int?,
        ownerProcessStartedAtSeconds: UInt64?,
        ownerProcessStartedAtMicroseconds: UInt64?
    ) -> Bool {
        guard let ownerProcessID,
              ownerProcessID > 1,
              ownerProcessID <= Int(Int32.max),
              let runtimeInstanceID,
              !runtimeInstanceID.isEmpty,
              let ownerProcessStartedAtSeconds,
              let ownerProcessStartedAtMicroseconds else { return false }
        return claim.ownerProcessID == Int32(ownerProcessID)
            && claim.instanceID == runtimeInstanceID
            && claim.ownerProcessStartedAtSeconds == ownerProcessStartedAtSeconds
            && claim.ownerProcessStartedAtMicroseconds == ownerProcessStartedAtMicroseconds
    }
}

protocol AgentRuntimeIdentityPersisting {
    @discardableResult
    func save(claim: AgentRuntimeIdentityClaim, for paneID: Conversation.ID) -> Bool
    @discardableResult
    func revoke(for paneID: Conversation.ID) -> Bool
    func loadClaim(for paneID: Conversation.ID) -> AgentRuntimeIdentityClaim?
}

struct AgentRuntimeIdentityKeychainStore: AgentRuntimeIdentityPersisting {
    private static let revokedMarker = "soyeht.revoked-runtime-identity.v1"
    private let keychain = KeychainHelper(
        service: SoyehtInstallProfile.current.keychainService + ".agent-runtime-identity"
    )

    private func account(for paneID: Conversation.ID) -> String {
        "pane.\(paneID.uuidString.lowercased())"
    }

    @discardableResult
    func save(claim: AgentRuntimeIdentityClaim, for paneID: Conversation.ID) -> Bool {
        guard let data = try? JSONEncoder().encode(claim),
              let encoded = String(data: data, encoding: .utf8) else { return false }
        return keychain.saveString(encoded, account: account(for: paneID))
    }

    @discardableResult
    func revoke(for paneID: Conversation.ID) -> Bool {
        // A tombstone shadows legacy-keychain fallback rows just like launch
        // ownership does. Deletion alone could revive an older claim.
        keychain.saveString(Self.revokedMarker, account: account(for: paneID))
    }

    func loadClaim(for paneID: Conversation.ID) -> AgentRuntimeIdentityClaim? {
        guard let encoded = keychain.loadString(account: account(for: paneID)),
              encoded != Self.revokedMarker,
              let data = encoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentRuntimeIdentityClaim.self, from: data)
    }
}

final class AgentRuntimeIdentityRegistry {
    private var claimsByPane: [Conversation.ID: AgentRuntimeIdentityClaim] = [:]
    private let isProcessAlive: (Int32) -> Bool
    private let processStartTime: (Int32) -> (seconds: UInt64, microseconds: UInt64)?
    private let processTTYDevice: (Int32) -> UInt32?
    private let processParentID: (Int32) -> Int32?
    private let persistence: AgentRuntimeIdentityPersisting

    init(
        isProcessAlive: @escaping (Int32) -> Bool = AgentRuntimeIdentityRegistry.defaultProcessLiveness,
        processStartTime: @escaping (Int32) -> (seconds: UInt64, microseconds: UInt64)? = AgentRuntimeIdentityRegistry.defaultProcessStartTime,
        processTTYDevice: @escaping (Int32) -> UInt32? = AgentRuntimeIdentityRegistry.defaultProcessTTYDevice,
        processParentID: @escaping (Int32) -> Int32? = AgentRuntimeIdentityRegistry.defaultProcessParentID,
        persistence: AgentRuntimeIdentityPersisting = AgentRuntimeIdentityKeychainStore()
    ) {
        self.isProcessAlive = isProcessAlive
        self.processStartTime = processStartTime
        self.processTTYDevice = processTTYDevice
        self.processParentID = processParentID
        self.persistence = persistence
    }

    private static func defaultProcessLiveness(_ processID: Int32) -> Bool {
        guard processID > 1 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func defaultProcessStartTime(
        _ processID: Int32
    ) -> (seconds: UInt64, microseconds: UInt64)? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            soyeht_agent_runtime_proc_pidinfo(
                processID,
                Int32(PROC_PIDTBSDINFO),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard written == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    private static func defaultProcessTTYDevice(_ processID: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            soyeht_agent_runtime_proc_pidinfo(
                processID,
                Int32(PROC_PIDTBSDINFO),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard written == MemoryLayout<proc_bsdinfo>.size,
              info.e_tdev != 0,
              info.e_tdev != UInt32.max else { return nil }
        return info.e_tdev
    }

    private static func defaultProcessParentID(_ processID: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            soyeht_agent_runtime_proc_pidinfo(
                processID,
                Int32(PROC_PIDTBSDINFO),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard written == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_ppid > 1 else { return nil }
        return Int32(info.pbi_ppid)
    }

    private func validatedClaim(
        agentName: String,
        instanceID: String,
        processID: Int,
        ownerProcessID: Int,
        expectedTTYDevice: UInt32?
    ) -> AgentRuntimeIdentityClaim? {
        let normalizedAgent = agentName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedInstance = instanceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAgent.isEmpty,
              normalizedAgent != "shell",
              !normalizedInstance.isEmpty,
              processID > 1,
              processID <= Int(Int32.max),
              ownerProcessID > 1,
              ownerProcessID <= Int(Int32.max),
              isProcessAlive(Int32(processID)),
              isProcessAlive(Int32(ownerProcessID)),
              processParentID(Int32(processID)) == Int32(ownerProcessID),
              let startedAt = processStartTime(Int32(processID)),
              let ownerStartedAt = processStartTime(Int32(ownerProcessID)) else { return nil }
        let observedTTYDevice = processTTYDevice(Int32(processID))
        if let expectedTTYDevice {
            guard observedTTYDevice == expectedTTYDevice else {
                return nil
            }
        }
        return AgentRuntimeIdentityClaim(
            agentName: normalizedAgent,
            instanceID: normalizedInstance,
            processID: Int32(processID),
            processStartedAtSeconds: startedAt.seconds,
            processStartedAtMicroseconds: startedAt.microseconds,
            ownerProcessID: Int32(ownerProcessID),
            ownerProcessStartedAtSeconds: ownerStartedAt.seconds,
            ownerProcessStartedAtMicroseconds: ownerStartedAt.microseconds,
            ttyDevice: expectedTTYDevice ?? observedTTYDevice
        )
    }

    /// Side-effect-free preflight used before durably revoking authority held
    /// by the previous runtime. `claim` repeats every kernel check afterwards;
    /// a race therefore fails closed with the old grant already revoked.
    func canClaim(
        agentName: String,
        instanceID: String,
        processID: Int,
        ownerProcessID: Int,
        expectedTTYDevice: UInt32? = nil
    ) -> Bool {
        validatedClaim(
            agentName: agentName,
            instanceID: instanceID,
            processID: processID,
            ownerProcessID: ownerProcessID,
            expectedTTYDevice: expectedTTYDevice
        ) != nil
    }

    @discardableResult
    func claim(
        paneID: Conversation.ID,
        agentName: String,
        instanceID: String,
        processID: Int,
        ownerProcessID: Int,
        expectedTTYDevice: UInt32? = nil
    ) -> AgentRuntimeIdentityClaim? {
        guard let claim = validatedClaim(
            agentName: agentName,
            instanceID: instanceID,
            processID: processID,
            ownerProcessID: ownerProcessID,
            expectedTTYDevice: expectedTTYDevice
        ) else { return nil }
        guard persistence.save(claim: claim, for: paneID) else { return nil }
        claimsByPane[paneID] = claim
        return claim
    }

    @discardableResult
    func release(paneID: Conversation.ID, instanceID: String) -> Bool {
        guard claimsByPane[paneID]?.instanceID == instanceID else { return false }
        guard persistence.revoke(for: paneID) else { return false }
        claimsByPane[paneID] = nil
        return true
    }

    func clear(paneID: Conversation.ID) {
        if persistence.revoke(for: paneID) {
            claimsByPane[paneID] = nil
        }
    }

    @discardableResult
    func rehydrate(from conversations: [Conversation]) -> Set<Conversation.ID> {
        var trustedPaneIDs = Set<Conversation.ID>()
        for conversation in conversations {
            guard conversation.agent.isShell,
                  conversation.content.isTerminal,
                  case .engineLocal = conversation.commander,
                  let claim = persistence.loadClaim(for: conversation.id) else { continue }
            if claim.ttyDevice != nil,
               claim.ownerProcessID != nil,
               claim.ownerProcessStartedAtSeconds != nil,
               claim.ownerProcessStartedAtMicroseconds != nil,
               isCurrentProcess(claim) {
                claimsByPane[conversation.id] = claim
                trustedPaneIDs.insert(conversation.id)
            } else {
                _ = persistence.revoke(for: conversation.id)
            }
        }
        return trustedPaneIDs
    }

    func claim(
        for paneID: Conversation.ID,
        expectedTTYDevice: UInt32? = nil
    ) -> AgentRuntimeIdentityClaim? {
        guard let claim = claimsByPane[paneID] else { return nil }
        guard isCurrentProcess(claim, expectedTTYDevice: expectedTTYDevice) else {
            _ = persistence.revoke(for: paneID)
            claimsByPane[paneID] = nil
            return nil
        }
        return claim
    }

    private func isCurrentProcess(
        _ claim: AgentRuntimeIdentityClaim,
        expectedTTYDevice: UInt32? = nil
    ) -> Bool {
        guard isProcessAlive(claim.processID),
              let startedAt = processStartTime(claim.processID) else { return false }
        guard startedAt.seconds == claim.processStartedAtSeconds,
              startedAt.microseconds == claim.processStartedAtMicroseconds else {
            return false
        }
        guard let ownerProcessID = claim.ownerProcessID,
              let ownerStartedAtSeconds = claim.ownerProcessStartedAtSeconds,
              let ownerStartedAtMicroseconds = claim.ownerProcessStartedAtMicroseconds,
              isProcessAlive(ownerProcessID),
              processParentID(claim.processID) == ownerProcessID,
              let ownerStartedAt = processStartTime(ownerProcessID),
              ownerStartedAt.seconds == ownerStartedAtSeconds,
              ownerStartedAt.microseconds == ownerStartedAtMicroseconds else {
            return false
        }
        if let claimTTYDevice = claim.ttyDevice {
            guard processTTYDevice(claim.processID) == claimTTYDevice else { return false }
        }
        if let expectedTTYDevice {
            guard claim.ttyDevice == expectedTTYDevice,
                  processTTYDevice(claim.processID) == expectedTTYDevice else {
                return false
            }
        }
        return true
    }

    func validates(
        paneID: Conversation.ID,
        agentName: String?,
        instanceID: String?,
        expectedTTYDevice: UInt32? = nil
    ) -> Bool {
        guard let agentName, let instanceID else { return false }
        guard let claim = claim(
            for: paneID,
            expectedTTYDevice: expectedTTYDevice
        ) else { return false }
        return claim.agentName == agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && claim.instanceID == instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
