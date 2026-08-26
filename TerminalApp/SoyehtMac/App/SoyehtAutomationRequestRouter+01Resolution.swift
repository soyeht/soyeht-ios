//
//  SoyehtAutomationRequestRouter domain extension
//  Soyeht
//

import Cocoa
import ApplicationServices
import Darwin
import os
import SoyehtCore

@MainActor
extension SoyehtAutomationRequestRouter {
    func requestedWindowID(_ payload: SoyehtAutomationRequest.Payload) -> String? {
        let raw = payload.targetWindowID ?? payload.windowID
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func requestedWorkspaceID(_ payload: SoyehtAutomationRequest.Payload) throws -> Workspace.ID? {
        let raw = payload.workspaceID ?? payload.workspaceIDs?.first
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let id = Workspace.ID(uuidString: trimmed) else {
            throw SoyehtAutomationError.invalidWorkspaceIDFormat(trimmed)
        }
        return id
    }

    func automationWindow(id: String) throws -> SoyehtMainWindowController {
        guard let controller = mainWindowControllers().first(where: { $0.windowID == id }) else {
            throw SoyehtAutomationError.windowNotFound(id)
        }
        return controller
    }

    func automationTargetWindow(
        payload: SoyehtAutomationRequest.Payload,
        createIfMissing: Bool = true
    ) throws -> SoyehtMainWindowController {
        if let id = requestedWindowID(payload) {
            return try automationWindow(id: id)
        }
        if let target = try automationWindowForWorkspace(payload) {
            return target
        }
        if let target = automationWindowForPaneTargets(payload) {
            return target
        }
        if let target = automationWindowForSource(payload) {
            return target
        }
        if let target = activeMainWindowController() {
            return target
        }
        if createIfMissing {
            return openNewMainWindow()
        }
        throw SoyehtAutomationError.noActiveMainWindow
    }

    func automationWindowForWorkspace(
        _ payload: SoyehtAutomationRequest.Payload
    ) throws -> SoyehtMainWindowController? {
        guard let workspaceID = try requestedWorkspaceID(payload),
              let windowID = windowID(containingWorkspace: workspaceID) else {
            return nil
        }
        return try automationWindow(id: windowID)
    }

    func automationWindowForPaneTargets(
        _ payload: SoyehtAutomationRequest.Payload
    ) -> SoyehtMainWindowController? {
        var windowIDs: Set<String> = []

        for rawID in payload.conversationIDs ?? [] {
            guard let id = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let conversation = conversationStore.conversation(id),
                  let windowID = windowID(containingWorkspace: conversation.workspaceID) else {
                continue
            }
            windowIDs.insert(windowID)
        }

        let normalizedHandles = (payload.handles ?? [])
            .map { ConversationStore.normalize($0) }
            .filter { !$0.isEmpty }
        for handle in normalizedHandles {
            let matches = conversationStore.all.filter {
                ConversationStore.normalize($0.handle) == handle
            }
            let matchWindowIDs = Set(matches.compactMap {
                windowID(containingWorkspace: $0.workspaceID)
            })
            guard matchWindowIDs.count == 1 else {
                continue
            }
            windowIDs.formUnion(matchWindowIDs)
        }

        return uniqueAutomationWindow(for: windowIDs)
    }

    func automationWindowForSource(
        _ payload: SoyehtAutomationRequest.Payload
    ) -> SoyehtMainWindowController? {
        guard let source = try? resolveAutomationSource(payload: payload),
              let windowID = windowID(containingWorkspace: source.conversation.workspaceID) else {
            return nil
        }
        return try? automationWindow(id: windowID)
    }

    func uniqueAutomationWindow(
        for windowIDs: Set<String>
    ) -> SoyehtMainWindowController? {
        guard windowIDs.count == 1, let windowID = windowIDs.first else {
            return nil
        }
        return try? automationWindow(id: windowID)
    }

    func automationMoveDestinationWindow(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> SoyehtMainWindowController {
        if let raw = payload.destinationWindowID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return try automationWindow(id: raw)
        }
        return try automationTargetWindow(payload: payload)
    }

    func automationWorkspaceID(
        payload: SoyehtAutomationRequest.Payload,
        in target: SoyehtMainWindowController
    ) throws -> Workspace.ID? {
        if let explicitWorkspaceID = try requestedWorkspaceID(payload) {
            guard workspaceStore.workspace(explicitWorkspaceID, isInWindow: target.windowID) else {
                throw SoyehtAutomationError.workspaceNotInWindow(explicitWorkspaceID, target.windowID)
            }
            return explicitWorkspaceID
        }

        guard let source = try? resolveAutomationSource(payload: payload),
              let sourceWindowID = windowID(containingWorkspace: source.conversation.workspaceID),
              sourceWindowID == target.windowID else {
            return nil
        }
        return source.conversation.workspaceID
    }

    func automationDisplayName(
        _ value: String?,
        fallback: String,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? value!
            : fallback
        return SoyehtAutomationNameFormatter.displayName(raw, kind: kind, style: style)
    }

    func optionalAutomationDisplayName(
        _ value: String?,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SoyehtAutomationNameFormatter.displayName(value, kind: kind, style: style)
    }

    func automationPaneName(
        _ value: String?,
        path: String,
        style: String?,
        allowsAutomaticName: Bool
    ) throws -> String? {
        if let displayName = optionalAutomationDisplayName(value, kind: .pane, style: style) {
            return displayName
        }
        guard allowsAutomaticName else {
            throw SoyehtAutomationError.missingPaneName(path)
        }
        return nil
    }

    func automationTTYPath(for conversation: Conversation) -> String? {
        let engineConversationID: String? = {
            if case .engineLocal(let id) = conversation.commander { return id }
            return nil
        }()
        let livePane = LivePaneRegistry.shared.pane(
            for: conversation.id
        ) as? PaneViewController
        return livePane?.terminalView.localPTYSlaveTTYPathForAutomation
            ?? engineConversationID.flatMap {
                EngineSessionTTYRegistry.slaveTTYPath(forConversationID: $0)
            }
    }

    func automationTTYDevice(for conversation: Conversation) -> UInt32? {
        guard let ttyPath = automationTTYPath(for: conversation) else {
            return nil
        }
        var metadata = stat()
        guard stat(ttyPath, &metadata) == 0 else { return nil }
        return UInt32(metadata.st_rdev)
    }

    func claimedRuntimeReportIdentity(
        for source: Conversation,
        expectedTTYDevice: UInt32
    ) -> SoyehtAutomationResponse.RuntimeIdentityClaimed? {
        guard source.agent.isShell,
              let claim = PaneStatusTracker.shared.runtimeIdentityClaim(
                  for: source.id,
                  expectedTTYDevice: expectedTTYDevice
              ),
              let ownerProcessID = claim.ownerProcessID,
              let seconds = claim.ownerProcessStartedAtSeconds,
              let microseconds = claim.ownerProcessStartedAtMicroseconds else { return nil }
        return .init(
            conversationID: source.id.uuidString,
            runtimeAgent: claim.agentName,
            runtimeInstanceID: claim.instanceID,
            runtimeProcessStartedAtSeconds: claim.processStartedAtSeconds,
            runtimeProcessStartedAtMicroseconds: claim.processStartedAtMicroseconds,
            runtimeOwnerProcessID: ownerProcessID,
            runtimeOwnerProcessStartedAtSeconds: seconds,
            runtimeOwnerProcessStartedAtMicroseconds: microseconds
        )
    }
}
