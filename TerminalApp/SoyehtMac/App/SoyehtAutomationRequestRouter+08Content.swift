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
    func handleGetActiveContext(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let target = try automationTargetWindow(payload: request.payload, createIfMissing: false)
        let source = try resolveAutomationSource(payload: request.payload)
        return SoyehtAutomationResult(
            activeContext: try makeActiveContext(target, payload: request.payload),
            sourceIdentity: source.map(sourceIdentity)
        )
    }

    func handleOpenEditor(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let fileURL = try payload.file.map { try existingFileURL($0) }
        let rootURL = try payload.root.map { try existingDirectoryURL($0) }
            ?? fileURL?.deletingLastPathComponent()
            ?? payload.path.map { try existingDirectoryURL($0) }
        let opened = try target.openEditorPane(
            fileURL: fileURL,
            rootURL: rootURL,
            line: payload.line,
            column: payload.column,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    func handleOpenExplorer(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.root ?? payload.path ?? payload.file else {
            throw SoyehtAutomationError.invalidDirectory("")
        }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openExplorerPane(
            rootURL: try existingDirectoryURL(rawPath),
            workspaceID: try automationWorkspaceID(payload: payload, in: target)
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    func handleOpenGit(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.repo ?? payload.repoPath ?? payload.path ?? payload.root else {
            throw SoyehtAutomationError.invalidDirectory("")
        }
        let target = try automationTargetWindow(payload: payload)
        let repoURL = try existingDirectoryURL(rawPath)
        let opened = try target.openGitPane(
            repoURL: repoURL,
            selectedFilePath: payload.selectedFile,
            branch: payload.branch,
            compareBase: payload.compareBase,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    func handleOpenDiff(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let selected = payload.selectedFile ?? payload.file
        let explicitRepo = payload.repo ?? payload.repoPath ?? payload.root ?? payload.path
        let repoCandidate: URL
        if let explicitRepo {
            repoCandidate = try existingDirectoryURL(explicitRepo)
        } else if let selected {
            repoCandidate = try existingFileURL(selected).deletingLastPathComponent()
        } else {
            throw SoyehtAutomationError.invalidDirectory("")
        }
        let repoRoot = try GitRepositoryService.resolveRepoRoot(from: repoCandidate)
        let selectedPath = selected.map { relativeGitPath($0, repoRoot: repoRoot) }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openGitPane(
            repoURL: repoRoot,
            selectedFilePath: selectedPath,
            branch: payload.branch,
            compareBase: payload.compareBase,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    func handleOpenWeb(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        // The Python MCP script is not a trust boundary: validation lives
        // here, fail-closed in WebURL.validate. normalizeUserInput is the
        // shared convenience pass (trim + https:// prefix for strict host
        // patterns) so the MCP entry and the pane URL bar behave the same.
        guard let rawURL = payload.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw SoyehtAutomationError.missingWebURL
        }
        let url = try WebURL.validate(WebURL.normalizeUserInput(rawURL))
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openWebPane(
            url: url,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            forceNew: payload.newPane ?? false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    func handleInstallApp(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw SoyehtAutomationError.invalidDirectory("")
        }
        // The bundle path arrives from outside (MCP script, agent), so it
        // gets the same fail-closed treatment the open_web URL got: the
        // Python script is not a trust boundary. PathScope gives the source
        // directory the same kernel-imposed confinement the scheme handler
        // will apply when serving it — a symlinked manifest is refused with
        // a distinguishable reason instead of being silently dereferenced.
        let bundleURL = try existingDirectoryURL(rawPath)
        let scope = try PathScope(rootDirectory: bundleURL)
        let manifestFD = try scope.openFileForReading(relativePath: "manifest.json")
        Darwin.close(manifestFD)
        scope.close()

        let record = try AppInstallStore.install(bundleAt: bundleURL)
        return SoyehtAutomationResult(installedApps: [
            SoyehtAutomationResponse.InstalledApp(
                installID: record.installID,
                appID: record.manifest.id,
                name: record.manifest.name,
                version: record.manifest.version,
                fingerprint: record.fingerprint
            )
        ])
    }

    func handleOpenApp(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let installID = payload.installID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installID.isEmpty else {
            throw SoyehtAutomationError.missingAppInstallID
        }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openAppPane(
            installID: installID,
            workspaceID: try automationWorkspaceID(payload: payload, in: target)
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    func openedSpecialPane(
        _ result: SoyehtMainWindowController.OpenedSpecialPaneResult,
        windowID: String
    ) -> SoyehtAutomationResponse.OpenedSpecialPane {
        // Web panes carry their URL in `result.url` (from the stored state)
        // and have an empty `path`: report the URL as path so the wire
        // describes what the model stores instead of a meaningless string.
        SoyehtAutomationResponse.OpenedSpecialPane(
            kind: result.kind.rawValue,
            path: result.url ?? result.path,
            workspaceID: result.workspaceID.uuidString,
            conversationID: result.conversationID.uuidString,
            handle: result.handle,
            reused: result.reused,
            windowID: windowID,
            url: result.url
        )
    }

    func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    func existingFileURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw SoyehtAutomationError.invalidFile(path)
        }
        return url
    }

    func existingDirectoryURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SoyehtAutomationError.invalidDirectory(path)
        }
        return url
    }

    func relativeGitPath(_ path: String, repoRoot: URL) -> String {
        let absolute = URL(fileURLWithPath: expandedPath(path), isDirectory: false)
            .standardizedFileURL
            .path
        let root = repoRoot.standardizedFileURL.path
        if absolute == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if absolute.hasPrefix(prefix) {
            return String(absolute.dropFirst(prefix.count))
        }
        return path
    }

    func makeActiveContext(
        _ target: SoyehtMainWindowController,
        payload: SoyehtAutomationRequest.Payload? = nil
    ) throws -> SoyehtAutomationResponse.ActiveContext {
        if let payload,
           let workspaceID = try automationWorkspaceID(payload: payload, in: target),
           let workspace = workspaceStore.workspace(workspaceID) {
            // Focus is shared UI state and can change while multiple agents
            // call the MCP concurrently. When a source pane is known, return
            // that caller instead of letting the focused sibling impersonate
            // it. Explicit requests for another workspace still use that
            // workspace's active pane.
            let source = try? resolveAutomationSource(payload: payload)
            let sourceConversation = source?.conversation.workspaceID == workspaceID
                ? source?.conversation
                : nil
            let paneID = sourceConversation?.id ?? workspace.activePaneID
            let handle = sourceConversation?.handle
                ?? paneID.flatMap { conversationStore.conversation($0)?.handle }
            return SoyehtAutomationResponse.ActiveContext(
                windowID: target.windowID,
                workspaceID: workspaceID.uuidString,
                workspaceName: workspace.name,
                paneID: paneID?.uuidString,
                paneHandle: handle
            )
        }
        let ctx = target.getActiveContext()
        return SoyehtAutomationResponse.ActiveContext(
            windowID: target.windowID,
            workspaceID: ctx.workspaceID.uuidString,
            workspaceName: ctx.workspaceName,
            paneID: ctx.paneID?.uuidString,
            paneHandle: ctx.paneHandle
        )
    }
}
