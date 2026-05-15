# API Contract: Workspace & Tmux Session Management

> Mapping between iOS client calls and existing backend endpoints.
> All endpoints require `Authorization: Bearer {session_token}` header.
> Base path: `/api/v1`

---

## Endpoints Used by Session List Screen (ec3Zq)

| iOS Action | Backend Endpoint | Status |
|---|---|---|
| List workspaces (sessions) | `GET /terminals/{container}/workspaces` | Exists |
| Create workspace (session) | `POST /terminals/{container}/workspaces` | Exists |
| Delete workspace (kill session) | `DELETE /terminals/{container}/workspaces/{id}` | Exists |
| Attach to workspace | `POST /terminals/{container}/workspace` | Exists |
| List tmux windows | `GET /terminals/{container}/tmux/windows?session=` | Exists |

---

## 1. List Workspaces

**`GET /api/v1/terminals/{container}/workspaces`**

iOS model: `SoyehtWorkspace` — fields are all optional except `id` for maximum compatibility.

```swift
struct SoyehtWorkspace: Decodable, Identifiable {
    let id: String
    let session_id: String?
    let display_name: String?
    let name: String?
    let container: String?
    let status: String?          // "attached", "active", "running", etc.
    let owner: String?
    let created_at: String?      // ISO 8601
    let windows: Int?
}
```

Client accepts both `{ "workspaces": [...] }` and bare array `[...]`.

---

## 2. List Tmux Windows

**`GET /api/v1/terminals/{container}/tmux/windows?session={session_name}`**

iOS model: `TmuxWindow` — flexible field names.

```swift
struct TmuxWindow: Decodable, Identifiable {
    let index: Int?              // or window_index
    let name: String?            // or window_name
    let panes: Int?              // or window_panes
    let is_active: Bool?
}
```

---

## 3. Create Workspace

**`POST /api/v1/terminals/{container}/workspaces`**

Body: `{ "name": "optional-name" }` or empty.

Response: `SoyehtWorkspace` (wrapped or bare).

---

## 4. Delete Workspace

**`DELETE /api/v1/terminals/{container}/workspaces/{id}`**

Kills tmux session + PTY + DB row.

---

## 5. Attach (Resume/Create)

**`POST /api/v1/terminals/{container}/workspace`** (singular, existing endpoint)

Body: `{ "session": "session-name" }` (optional — for targeting specific workspace)

Response: `{ "workspace": { "id", "sessionId", "container", "status" } }`

---

## Additional Tmux Endpoints (available but not yet used by iOS)

| Endpoint | Purpose |
|---|---|
| `POST /terminals/{container}/tmux/new-window` | Create window in session |
| `POST /terminals/{container}/tmux/select-window` | Switch active window |
| `DELETE /terminals/{container}/tmux/window/{index}` | Kill window |
| `GET /terminals/{container}/tmux/capture-pane` | Capture pane content |
| `PATCH /terminals/{container}/workspaces/{id}` | Rename workspace |

These will be useful for future tmux tab bar integration (switching windows from the iOS UI).

---

## iOS Client Implementation

- Models: `SoyehtWorkspace`, `TmuxWindow` in `SoyehtAPIClient.swift`
- Methods: `listWorkspaces()`, `listWindows()`, `createNewWorkspace()`, `deleteWorkspace()`
- UI: `SessionListSheet` in `InstanceListView.swift` — loading states, selection, create/kill/attach
