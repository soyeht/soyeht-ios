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
    func rehydrate(from conversations: [Conversation]) -> [Conversation.ID] {
        var migratedLegacyPaneIDs: [Conversation.ID] = []
        for conversation in conversations {
            guard case .engineLocal = conversation.commander,
                  conversation.content.isTerminal else { continue }
            if let persisted = persistence.loadNonce(for: conversation.id), !persisted.isEmpty {
                expectedByPane[conversation.id] = persisted
            } else if let legacy = conversation.agentLaunchOwnershipNonce, !legacy.isEmpty {
                if register(paneID: conversation.id, nonce: legacy) {
                    migratedLegacyPaneIDs.append(conversation.id)
                }
            }
        }
        return migratedLegacyPaneIDs
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
    private let persistence: AgentRuntimeIdentityPersisting

    init(
        isProcessAlive: @escaping (Int32) -> Bool = AgentRuntimeIdentityRegistry.defaultProcessLiveness,
        processStartTime: @escaping (Int32) -> (seconds: UInt64, microseconds: UInt64)? = AgentRuntimeIdentityRegistry.defaultProcessStartTime,
        persistence: AgentRuntimeIdentityPersisting = AgentRuntimeIdentityKeychainStore()
    ) {
        self.isProcessAlive = isProcessAlive
        self.processStartTime = processStartTime
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

    @discardableResult
    func claim(
        paneID: Conversation.ID,
        agentName: String,
        instanceID: String,
        processID: Int
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
              isProcessAlive(Int32(processID)),
              let startedAt = processStartTime(Int32(processID)) else { return nil }
        let claim = AgentRuntimeIdentityClaim(
            agentName: normalizedAgent,
            instanceID: normalizedInstance,
            processID: Int32(processID),
            processStartedAtSeconds: startedAt.seconds,
            processStartedAtMicroseconds: startedAt.microseconds
        )
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

    func rehydrate(from conversations: [Conversation]) {
        for conversation in conversations {
            guard conversation.agent.isShell,
                  conversation.content.isTerminal,
                  case .engineLocal = conversation.commander,
                  let claim = persistence.loadClaim(for: conversation.id) else { continue }
            if isCurrentProcess(claim) {
                claimsByPane[conversation.id] = claim
            } else {
                _ = persistence.revoke(for: conversation.id)
            }
        }
    }

    func claim(for paneID: Conversation.ID) -> AgentRuntimeIdentityClaim? {
        guard let claim = claimsByPane[paneID] else { return nil }
        guard isCurrentProcess(claim) else {
            _ = persistence.revoke(for: paneID)
            claimsByPane[paneID] = nil
            return nil
        }
        return claim
    }

    private func isCurrentProcess(_ claim: AgentRuntimeIdentityClaim) -> Bool {
        guard isProcessAlive(claim.processID),
              let startedAt = processStartTime(claim.processID) else { return false }
        return startedAt.seconds == claim.processStartedAtSeconds
            && startedAt.microseconds == claim.processStartedAtMicroseconds
    }

    func validates(
        paneID: Conversation.ID,
        agentName: String?,
        instanceID: String?
    ) -> Bool {
        guard let agentName, let instanceID else { return false }
        guard let claim = claim(for: paneID) else { return false }
        return claim.agentName == agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && claim.instanceID == instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
