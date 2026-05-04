import Darwin
import Foundation
import os

struct SoyehtAutomationRequest: Decodable {
    enum RequestType: String, Decodable {
        case createWorktreeWorkspaces = "create_worktree_workspaces"
        case createWorktreePanes = "create_worktree_panes"
        case sendPaneInput = "send_pane_input"
        case createWorktreeTabs = "create_worktree_tabs"
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
        let workspaces: [SessionSpec]?
        let panes: [SessionSpec]?
        let tabs: [SessionSpec]?
        let conversationIDs: [String]?
        let handles: [String]?
        let text: String?
        let appendNewline: Bool?

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
    }

    struct CreatedPane: Encodable {
        let name: String
        let path: String
        let workspaceID: String
        let conversationID: String
    }

    struct SentPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
    }

    let id: String
    let status: String
    let message: String?
    let createdWorkspaces: [CreatedWorkspace]
    let createdPanes: [CreatedPane]
    let sentPanes: [SentPane]
}

struct SoyehtAutomationResult {
    var createdWorkspaces: [SoyehtAutomationResponse.CreatedWorkspace] = []
    var createdPanes: [SoyehtAutomationResponse.CreatedPane] = []
    var sentPanes: [SoyehtAutomationResponse.SentPane] = []
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
                sentPanes: result.sentPanes
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
                sentPanes: []
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
