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
    func handleRenameWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let rawName = payload.newName ?? payload.workspaceName
        guard let rawName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SoyehtAutomationError.emptyRenameName
        }

        let target = try automationTargetWindow(payload: payload)
        let renamed = try target.renameWorkspaces(
            workspaceIDStrings: payload.workspaceIDs ?? [],
            workspaceNames: payload.workspaceNames ?? [],
            newName: rawName,
            nameStyle: payload.workspaceNameStyle ?? payload.nameStyle
        )
        guard !renamed.isEmpty else { throw SoyehtAutomationError.emptyRenameTargets }
        return SoyehtAutomationResult(renamedWorkspaces: renamed.map {
            SoyehtAutomationResponse.RenamedWorkspace(
                workspaceID: $0.workspaceID.uuidString,
                oldName: $0.oldName,
                name: $0.name,
                windowID: target.windowID
            )
        })
    }

    func handleRenamePanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawName = payload.newName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SoyehtAutomationError.emptyRenameName
        }

        let target = try automationTargetWindow(payload: payload)
        let renamed = try target.renamePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            newName: rawName,
            nameStyle: payload.paneNameStyle ?? payload.nameStyle
        )
        guard !renamed.isEmpty else { throw SoyehtAutomationError.emptyRenameTargets }
        return SoyehtAutomationResult(renamedPanes: renamed.map {
            SoyehtAutomationResponse.RenamedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                oldHandle: $0.oldHandle,
                handle: $0.handle,
                windowID: target.windowID
            )
        })
    }

    func handleArrangePanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let arranged = try target.arrangePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            layoutName: payload.layout,
            ratio: payload.ratio
        )
        return SoyehtAutomationResult(arrangedPaneLayouts: [
            SoyehtAutomationResponse.ArrangedPaneLayout(
                workspaceID: arranged.workspaceID.uuidString,
                layout: arranged.layout,
                conversationIDs: arranged.conversationIDs.map(\.uuidString),
                handles: arranged.handles
            )
        ])
    }

    func handleEmphasizePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let emphasized = try target.emphasizePane(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.mode,
            ratio: payload.ratio,
            position: payload.position
        )
        return SoyehtAutomationResult(emphasizedPanes: [
            SoyehtAutomationResponse.EmphasizedPane(
                conversationID: emphasized.conversationID.uuidString,
                workspaceID: emphasized.workspaceID.uuidString,
                handle: emphasized.handle,
                mode: emphasized.mode,
                ratio: emphasized.ratio,
                position: emphasized.position
            )
        ])
    }

    func handleResizePaneExact(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let resized = try target.resizePaneExact(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            position: payload.position,
            fraction: payload.fraction ?? payload.ratio,
            widthFraction: payload.widthFraction,
            heightFraction: payload.heightFraction
        )
        return SoyehtAutomationResult(resizedPanes: [
            SoyehtAutomationResponse.ResizedPane(
                conversationID: resized.conversationID.uuidString,
                workspaceID: resized.workspaceID.uuidString,
                handle: resized.handle,
                position: resized.position,
                fraction: resized.fraction,
                bounds: automationBounds(resized.bounds),
                pixelBounds: automationBounds(resized.pixelBounds),
                windowID: target.windowID
            )
        ])
    }

    func handleSetPaneFontSize(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let adjusted = try target.setPaneFontSize(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            fontSize: payload.fontSize,
            delta: payload.delta,
            persist: payload.persist ?? false
        )
        return SoyehtAutomationResult(adjustedPaneFonts: adjusted.map {
            SoyehtAutomationResponse.AdjustedPaneFont(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                fontSize: $0.fontSize,
                persisted: $0.persisted,
                columns: $0.columns,
                rows: $0.rows,
                windowID: target.windowID
            )
        })
    }

    func handleScrollPane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let scrolled = try target.scrollPanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.mode ?? payload.direction,
            lines: payload.lines,
            position: payload.scrollPosition ?? payload.fraction ?? payload.ratio,
            row: payload.row
        )
        return SoyehtAutomationResult(scrolledPanes: scrolled.map {
            SoyehtAutomationResponse.ScrolledPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                row: $0.row,
                position: $0.position,
                canScroll: $0.canScroll,
                isScrolledToBottom: $0.isScrolledToBottom,
                windowID: target.windowID
            )
        })
    }

    func automationBounds(
        _ bounds: SoyehtMainWindowController.PaneBoundsResult?
    ) -> SoyehtAutomationResponse.PaneBounds? {
        guard let bounds else { return nil }
        return SoyehtAutomationResponse.PaneBounds(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height
        )
    }
}
