import Foundation
import SoyehtCore

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
                  !conversation.agent.isShell else { continue }
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
        // rehydrate pass. Lazy reads could resurrect a stale row for a pane
        // that has since become a shell or changed ownership.
        let stored = expectedByPane[paneID]
        guard stored != Self.revokedMarker else { return nil }
        return stored
    }

    func validates(paneID: Conversation.ID, nonce: String?) -> Bool {
        guard let nonce, !nonce.isEmpty, let expected = self.nonce(for: paneID) else { return false }
        return nonce == expected
    }
}
