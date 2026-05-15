import Testing
import Foundation
import SoyehtCore
@testable import Soyeht

@Suite("PaneEntry — JSON decoding + icon mapping for Fase 2 presence", .serialized)
struct PaneEntryTests {

    @Test("decodes a minimal snapshot entry")
    func decodesMinimal() {
        let json: [String: Any] = [
            "id": "A1B2C3D4-0000-0000-0000-000000000001",
            "title": "@shell",
            "agent": PaneWireAgent.shell,
            "status": PaneWireStatus.active,
        ]
        let entry = PaneEntry.from(json: json)
        #expect(entry != nil)
        #expect(entry?.id == "A1B2C3D4-0000-0000-0000-000000000001")
        #expect(entry?.title == "@shell")
        #expect(entry?.agent == PaneWireAgent.shell)
        #expect(entry?.status == PaneWireStatus.active)
        #expect(entry?.createdAt == nil) // missing → nil
    }

    @Test("defaults title to id and agent to shell when missing")
    func fallbacksApplied() {
        let json: [String: Any] = ["id": "pane-42"]
        let entry = PaneEntry.from(json: json)
        #expect(entry?.title == "pane-42")
        #expect(entry?.agent == PaneWireAgent.shell)
        #expect(entry?.status == PaneWireStatus.active)
    }

    @Test("parses ISO8601 createdAt")
    func parsesCreatedAt() {
        let json: [String: Any] = [
            "id": "p-1",
            "created_at": "2026-04-18T12:00:00Z",
        ]
        let entry = PaneEntry.from(json: json)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(entry?.createdAt == formatter.date(from: "2026-04-18T12:00:00Z"))
    }

    @Test("returns nil when id missing")
    func requiresID() {
        let json: [String: Any] = ["title": "something"]
        let entry = PaneEntry.from(json: json)
        #expect(entry == nil)
    }

    @Test("decodes mirror metadata for workspace panes")
    func decodesMirrorMetadata() {
        let json: [String: Any] = [
            "id": "p-1",
            "title": "@codex",
            "agent": PaneWireAgent.codex,
            "status": PaneWireStatus.active,
            "workspace_id": "w-1",
            "window_id": "win-1",
            "is_focused": true,
            "is_live": true,
            "is_attachable": true,
            "order_index": 2,
            "working_directory": "/tmp/project",
        ]
        let entry = PaneEntry.from(json: json)
        #expect(entry?.workspaceID == "w-1")
        #expect(entry?.windowID == "win-1")
        #expect(entry?.isFocused == true)
        #expect(entry?.isLive == true)
        #expect(entry?.isAttachable == true)
        #expect(entry?.orderIndex == 2)
        #expect(entry?.workingDirectory == "/tmp/project")
    }

    @Test("workspace entry orders panes by layout tree")
    func workspaceEntryOrdersPanesByLayout() throws {
        let json: [String: Any] = [
            "id": "w-1",
            "name": "Main",
            "kind": "adhoc",
            "active_pane_id": "b",
            "is_active": true,
            "pane_count": 2,
            "order_index": 0,
            "layout": [
                "type": "split",
                "axis": "vertical",
                "ratio": 0.5,
                "children": [
                    ["type": "leaf", "pane_id": "b"],
                    ["type": "leaf", "pane_id": "a"],
                ],
            ],
            "panes": [
                ["id": "a", "title": "@a"],
                ["id": "b", "title": "@b"],
            ],
        ]
        let workspace = try #require(WorkspaceEntry.from(json: json))
        #expect(workspace.isActive)
        #expect(workspace.activePaneID == "b")
        #expect(workspace.orderedPaneRows.map { $0.pane.id } == ["b", "a"])
        #expect(workspace.orderedPaneRows.map(\.depth) == [1, 1])
    }

    @Test("workspace entry keeps non-attachable empty panes in layout order")
    func workspaceEntryKeepsEmptyPanes() throws {
        let json: [String: Any] = [
            "id": "w-1",
            "name": "Main",
            "kind": "adhoc",
            "is_active": true,
            "pane_count": 2,
            "order_index": 0,
            "layout": [
                "type": "split",
                "axis": "vertical",
                "ratio": 0.5,
                "children": [
                    ["type": "leaf", "pane_id": "session"],
                    ["type": "leaf", "pane_id": "empty"],
                ],
            ],
            "panes": [
                ["id": "session", "title": "@shell", "is_attachable": true],
                ["id": "empty", "title": "no session", "is_live": false, "is_attachable": false],
            ],
        ]
        let workspace = try #require(WorkspaceEntry.from(json: json))
        #expect(workspace.paneCount == 2)
        #expect(workspace.orderedPaneRows.map { $0.pane.title } == ["@shell", "no session"])
        #expect(workspace.orderedPaneRows.last?.pane.isAttachable == false)
    }

    @Test("icon mapping — claude → sparkles, codex → curlybraces, hermes → bolt, shell → terminal")
    func iconMapping() {
        let claude = PaneEntry(id: "1", title: "", agent: PaneWireAgent.claude, status: PaneWireStatus.active, createdAt: nil)
        let codex = PaneEntry(id: "2", title: "", agent: PaneWireAgent.codex, status: PaneWireStatus.active, createdAt: nil)
        let hermes = PaneEntry(id: "3", title: "", agent: PaneWireAgent.hermes, status: PaneWireStatus.active, createdAt: nil)
        let shell = PaneEntry(id: "4", title: "", agent: PaneWireAgent.shell, status: PaneWireStatus.active, createdAt: nil)
        let unknown = PaneEntry(id: "5", title: "", agent: "future-agent", status: PaneWireStatus.active, createdAt: nil)
        #expect(claude.iconName == "sparkles")
        #expect(codex.iconName == "curlybraces")
        #expect(hermes.iconName == "bolt")
        #expect(shell.iconName == "terminal")
        #expect(unknown.iconName == "rectangle.split.2x1")
    }
}
