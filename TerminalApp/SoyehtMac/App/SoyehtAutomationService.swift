import Darwin
import Foundation
import os

struct SoyehtAutomationRequest: Decodable {
    enum RequestType: String, Decodable {
        case createWorktreeWorkspaces = "create_worktree_workspaces"
        case createWorktreePanes = "create_worktree_panes"
        case createWorkspacePanes = "create_workspace_panes"
        case sendPaneInput = "send_pane_input"
        case renameWorkspace = "rename_workspace"
        case renamePanes = "rename_panes"
        case arrangePanes = "arrange_panes"
        case emphasizePane = "emphasize_pane"
        case createWorktreeTabs = "create_worktree_tabs"
        case listWindows = "list_windows"
        case listWorkspaces = "list_workspaces"
        case listPanes = "list_panes"
        case closePane = "close_pane"
        case closeWorkspace = "close_workspace"
        case movePaneToWorkspace = "move_pane"
        case getPaneStatus = "get_pane_status"
        case getActiveContext = "get_active_context"
    }

    struct Payload: Decodable {
        struct SessionSpec: Decodable {
            let name: String
            let path: String
            let branch: String?
            let agent: String?
            let command: String?
            let prompt: String?
            let promptDelayMs: Int?
        }

        let repoPath: String?
        let agent: String?
        let command: String?
        let prompt: String?
        let promptDelayMs: Int?
        let workspaceName: String?
        let workspaceBranch: String?
        let workspaceIDs: [String]?
        let workspaceNames: [String]?
        let workspaces: [SessionSpec]?
        let panes: [SessionSpec]?
        let tabs: [SessionSpec]?
        let conversationIDs: [String]?
        let handles: [String]?
        let text: String?
        let newName: String?
        let nameStyle: String?
        let paneNameStyle: String?
        let workspaceNameStyle: String?
        let appendNewline: Bool?
        let lineEnding: String?
        let layout: String?
        let mode: String?
        let ratio: Double?
        let position: String?
        let destinationWorkspaceID: String?
        let destinationWorkspaceName: String?
        let windowID: String?
        let targetWindowID: String?
        let destinationWindowID: String?

        var requestedWorkspaces: [SessionSpec] {
            workspaces ?? tabs ?? []
        }

        var requestedPanes: [SessionSpec] {
            panes ?? tabs ?? []
        }
    }

    let id: String
    let type: RequestType
    let payload: Payload
}

struct SoyehtAutomationResponse: Encodable {
    struct CreatedWorkspace: Encodable {
        let name: String
        let path: String
        let workspaceID: String
        let conversationID: String
        let handle: String
        let windowID: String?

        init(name: String, path: String, workspaceID: String, conversationID: String, handle: String, windowID: String? = nil) {
            self.name = name
            self.path = path
            self.workspaceID = workspaceID
            self.conversationID = conversationID
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct CreatedPane: Encodable {
        let name: String
        let path: String
        let workspaceID: String
        let conversationID: String
        let handle: String
        let windowID: String?

        init(name: String, path: String, workspaceID: String, conversationID: String, handle: String, windowID: String? = nil) {
            self.name = name
            self.path = path
            self.workspaceID = workspaceID
            self.conversationID = conversationID
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct SentPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let windowID: String?

        init(conversationID: String, workspaceID: String, handle: String, windowID: String? = nil) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct RenamedWorkspace: Encodable {
        let workspaceID: String
        let oldName: String
        let name: String
        let windowID: String?

        init(workspaceID: String, oldName: String, name: String, windowID: String? = nil) {
            self.workspaceID = workspaceID
            self.oldName = oldName
            self.name = name
            self.windowID = windowID
        }
    }

    struct RenamedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let oldHandle: String
        let handle: String
        let windowID: String?

        init(conversationID: String, workspaceID: String, oldHandle: String, handle: String, windowID: String? = nil) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.oldHandle = oldHandle
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct ArrangedPaneLayout: Encodable {
        let workspaceID: String
        let layout: String
        let conversationIDs: [String]
        let handles: [String]
    }

    struct EmphasizedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let mode: String
        let ratio: Double?
        let position: String?
    }

    struct ListedWorkspace: Encodable {
        let workspaceID: String
        let name: String
        let paneCount: Int
        let isActive: Bool
        let activePaneID: String?
        let windowID: String?

        init(workspaceID: String, name: String, paneCount: Int, isActive: Bool, activePaneID: String?, windowID: String? = nil) {
            self.workspaceID = workspaceID
            self.name = name
            self.paneCount = paneCount
            self.isActive = isActive
            self.activePaneID = activePaneID
            self.windowID = windowID
        }
    }

    struct ListedWindow: Encodable {
        let windowID: String
        let title: String
        let isKey: Bool
        let isMain: Bool
        let isVisible: Bool
        let isMiniaturized: Bool
        let activeWorkspaceID: String
        let activeWorkspaceName: String
        let workspaceCount: Int
        let paneCount: Int
        let workspaces: [ListedWorkspace]
    }

    struct ListedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let path: String
        let agent: String
        let isActive: Bool
        let isActiveWorkspace: Bool
        let windowID: String?

        init(conversationID: String, workspaceID: String, handle: String, path: String, agent: String, isActive: Bool, isActiveWorkspace: Bool, windowID: String? = nil) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.handle = handle
            self.path = path
            self.agent = agent
            self.isActive = isActive
            self.isActiveWorkspace = isActiveWorkspace
            self.windowID = windowID
        }
    }

    struct ActiveContext: Encodable {
        let windowID: String
        let workspaceID: String
        let workspaceName: String
        let paneID: String?
        let paneHandle: String?
    }

    struct ClosedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
    }

    struct ClosedWorkspace: Encodable {
        let workspaceID: String
        let name: String
    }

    struct MovedPane: Encodable {
        let conversationID: String
        let sourceWorkspaceID: String
        let destinationWorkspaceID: String
        let handle: String
    }

    struct PaneStatus: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let agent: String
        let status: String
        let exitCode: Int?
    }

    let id: String
    let status: String
    let message: String?
    let createdWorkspaces: [CreatedWorkspace]
    let createdPanes: [CreatedPane]
    let sentPanes: [SentPane]
    let renamedWorkspaces: [RenamedWorkspace]
    let renamedPanes: [RenamedPane]
    let arrangedPaneLayouts: [ArrangedPaneLayout]
    let emphasizedPanes: [EmphasizedPane]
    let listedWindows: [ListedWindow]
    let listedWorkspaces: [ListedWorkspace]
    let listedPanes: [ListedPane]
    let closedPanes: [ClosedPane]
    let closedWorkspaces: [ClosedWorkspace]
    let movedPanes: [MovedPane]
    let paneStatuses: [PaneStatus]
    let activeContext: ActiveContext?
}

struct SoyehtAutomationResult {
    var createdWorkspaces: [SoyehtAutomationResponse.CreatedWorkspace] = []
    var createdPanes: [SoyehtAutomationResponse.CreatedPane] = []
    var sentPanes: [SoyehtAutomationResponse.SentPane] = []
    var renamedWorkspaces: [SoyehtAutomationResponse.RenamedWorkspace] = []
    var renamedPanes: [SoyehtAutomationResponse.RenamedPane] = []
    var arrangedPaneLayouts: [SoyehtAutomationResponse.ArrangedPaneLayout] = []
    var emphasizedPanes: [SoyehtAutomationResponse.EmphasizedPane] = []
    var listedWindows: [SoyehtAutomationResponse.ListedWindow] = []
    var listedWorkspaces: [SoyehtAutomationResponse.ListedWorkspace] = []
    var listedPanes: [SoyehtAutomationResponse.ListedPane] = []
    var closedPanes: [SoyehtAutomationResponse.ClosedPane] = []
    var closedWorkspaces: [SoyehtAutomationResponse.ClosedWorkspace] = []
    var movedPanes: [SoyehtAutomationResponse.MovedPane] = []
    var paneStatuses: [SoyehtAutomationResponse.PaneStatus] = []
    var activeContext: SoyehtAutomationResponse.ActiveContext? = nil
}

enum SoyehtAutomationNameKind {
    case pane
    case workspace
}

enum SoyehtAutomationNameFormatter {
    static func displayName(
        _ value: String,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String {
        let fallback = kind == .pane ? "pane" : "Workspace"
        let collapsed = collapseWhitespace(value)
        guard !collapsed.isEmpty else { return fallback }

        switch normalizedStyle(style) {
        case "verbatim", "raw", "exact", "preserve":
            return collapsed
        case "full-hyphen", "full-kebab":
            return joinedWords(from: collapsed, separator: "-", limit: nil, fallback: fallback)
        case "full-space", "full-spaces":
            return joinedWords(from: collapsed, separator: " ", limit: nil, fallback: fallback)
        case "space", "spaces", "short-space":
            return joinedWords(from: collapsed, separator: " ", limit: 2, fallback: fallback)
        case "hyphen", "dash", "kebab", "short-hyphen":
            return joinedWords(from: collapsed, separator: "-", limit: 2, fallback: fallback)
        case "default", "short", "":
            if kind == .workspace {
                return joinedWords(from: collapsed, separator: " ", limit: 2, fallback: fallback)
            }
            return joinedWords(from: collapsed, separator: "-", limit: 2, fallback: fallback)
        default:
            if kind == .workspace {
                return joinedWords(from: collapsed, separator: " ", limit: 2, fallback: fallback)
            }
            return joinedWords(from: collapsed, separator: "-", limit: 2, fallback: fallback)
        }
    }

    private static func normalizedStyle(_ style: String?) -> String {
        style?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func joinedWords(
        from value: String,
        separator: String,
        limit: Int?,
        fallback: String
    ) -> String {
        let splitters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "_-/"))
        var words = value
            .components(separatedBy: splitters)
            .map { word in
                word.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) || $0 == "." }
                    .map(String.init)
                    .joined()
            }
            .filter { !$0.isEmpty }

        if let limit, words.count > limit {
            words = Array(words.prefix(limit))
        }
        let joined = words.joined(separator: separator)
        return joined.isEmpty ? fallback : joined
    }
}

@MainActor
final class SoyehtAutomationService {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "automation")

    typealias Handler = @MainActor (SoyehtAutomationRequest) async throws -> SoyehtAutomationResult

    private let handler: Handler
    private let rootURL: URL
    private let requestURL: URL
    private let responseURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var processing = false

    init(rootURL: URL = SoyehtAutomationService.defaultRootURL(), handler: @escaping Handler) {
        self.rootURL = rootURL
        self.requestURL = rootURL.appendingPathComponent("Requests", isDirectory: true)
        self.responseURL = rootURL.appendingPathComponent("Responses", isDirectory: true)
        self.handler = handler
    }

    func start() {
        guard source == nil else { return }
        do {
            try FileManager.default.createDirectory(at: requestURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: responseURL, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("automation_start_failed mkdir error=\(error.localizedDescription, privacy: .public)")
            return
        }

        processPendingRequests()

        directoryFD = open(requestURL.path, O_EVTONLY)
        guard directoryFD >= 0 else {
            Self.logger.error("automation_start_failed open errno=\(errno)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.processPendingRequests()
            }
        }
        source.setCancelHandler { [fd = directoryFD] in
            if fd >= 0 { close(fd) }
        }
        self.source = source
        source.resume()
        Self.logger.info("automation_ready root=\(self.rootURL.path, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        directoryFD = -1
    }

    private func processPendingRequests() {
        guard !processing else { return }
        processing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.processing = false
                if self.hasPendingRequestFiles() {
                    self.processPendingRequests()
                }
            }

            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: self.requestURL,
                    includingPropertiesForKeys: nil
                )
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                Self.logger.error("automation_scan_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }

            for file in files {
                await self.processRequestFile(file)
            }
        }
    }

    private func hasPendingRequestFiles() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestURL,
            includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }

    private func processRequestFile(_ file: URL) async {
        do {
            let data = try Data(contentsOf: file)
            let request = try JSONDecoder().decode(SoyehtAutomationRequest.self, from: data)
            try FileManager.default.removeItem(at: file)

            let result = try await handler(request)
            writeResponse(SoyehtAutomationResponse(
                id: request.id,
                status: "ok",
                message: nil,
                createdWorkspaces: result.createdWorkspaces,
                createdPanes: result.createdPanes,
                sentPanes: result.sentPanes,
                renamedWorkspaces: result.renamedWorkspaces,
                renamedPanes: result.renamedPanes,
                arrangedPaneLayouts: result.arrangedPaneLayouts,
                emphasizedPanes: result.emphasizedPanes,
                listedWindows: result.listedWindows,
                listedWorkspaces: result.listedWorkspaces,
                listedPanes: result.listedPanes,
                closedPanes: result.closedPanes,
                closedWorkspaces: result.closedWorkspaces,
                movedPanes: result.movedPanes,
                paneStatuses: result.paneStatuses,
                activeContext: result.activeContext
            ))
        } catch {
            let fallbackID = file.deletingPathExtension().lastPathComponent
            Self.logger.error("automation_request_failed file=\(file.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
            writeResponse(SoyehtAutomationResponse(
                id: fallbackID,
                status: "error",
                message: error.localizedDescription,
                createdWorkspaces: [],
                createdPanes: [],
                sentPanes: [],
                renamedWorkspaces: [],
                renamedPanes: [],
                arrangedPaneLayouts: [],
                emphasizedPanes: [],
                listedWindows: [],
                listedWorkspaces: [],
                listedPanes: [],
                closedPanes: [],
                closedWorkspaces: [],
                movedPanes: [],
                paneStatuses: [],
                activeContext: nil
            ))
        }
    }

    private func writeResponse(_ response: SoyehtAutomationResponse) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response)
            let destination = responseURL
                .appendingPathComponent(response.id)
                .appendingPathExtension("json")
            try data.write(to: destination, options: .atomic)
        } catch {
            Self.logger.error("automation_response_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func defaultRootURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SOYEHT_AUTOMATION_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("Soyeht", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
    }
}
