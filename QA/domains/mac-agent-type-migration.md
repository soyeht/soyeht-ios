---
id: mac-agent-type-migration
ids: ST-Q-MATM-001..014
profile: quick
automation: auto
requires_device: false
requires_backend: false
destructive: false
cleanup_required: false
platform: macOS
---

# macOS AgentType Reshape + Snapshot Migration

## Objective
Pin the contract guaranteeing that `AgentType` — reshaped from a closed 4-case enum (`shell, claude, codex, hermes`) to `.shell | .claw(String)` on `feat/claw-store-macos` — preserves **every v3 `Conversation` / `Snapshot` payload on disk**. The on-disk representation did NOT get a version bump for AgentType itself; instead, custom Codable maps the old raw strings (`"claude"`, `"codex"`, `"hermes"`, unknown claw names) onto `.claw(raw)` and `"shell"` onto `.shell`. The surrounding `WorkspaceStore.Snapshot` DOES get bumped from v3 → v4, and the migration runs in `WorkspaceStore.load()` — this domain covers both the wire contract and the snapshot migration round-trip.

## Risk
- A regression in the custom Codable decoder (e.g., reintroducing `AgentType: String, RawRepresentable`) would silently mean v3 payloads decode as `nil` and all saved conversations disappear.
- If the encoder writes the `.claw(name)` case as a structured object (`{"case":"claw","name":"claude"}`) instead of the bare string `"claude"`, v3 readers on OLDER builds would fail to decode — forward compatibility is broken. We encode as bare string on purpose.
- If `AgentType.canonicalCases` grows to include non-string cases, `ClawStoreView` cannot render them.
- `Conversation.commander` (which holds `instanceID` via `.mirror(instanceID:)`) is a separate axis; if AgentType ever gains an `instanceID` associated value, we would have TWO sources of truth → drift. This domain pins the invariant that AgentType carries ONLY identity / display, never instanceId.
- Snapshot migration v3 → v4: if `WorkspaceStore.load()` doesn't decode the old Snapshot with `ConversationV3` intermediate type, the decoder errors and the workspaces silently reset.
- If the migrator re-writes snapshots with `version = 4` without actually transforming conversations, a future reader won't know to re-run the migration on any missed entries.

## Preconditions
- Check out `feat/claw-store-macos` (or merged), macOS tests runnable via `cd TerminalApp/SoyehtMacTests && swift test`.
- For the snapshot-round-trip test (MATM-010..012), a real v3 `workspaces.json` fixture captured from `main` before this branch was merged. If no fixture exists yet, record one by running main's macOS build, creating 2 workspaces with conversations across all 4 legacy AgentTypes, quitting, and copying `~/Library/Containers/soyeht.SoyehtMac/Data/Library/Application Support/Soyeht/workspaces.json`.

## How to automate
- **Wire contract (MATM-001..009)**: SwiftPM tests in `TerminalApp/SoyehtMacTests/Tests/AgentTypeMigrationTests.swift`. Run `cd TerminalApp/SoyehtMacTests && swift test --filter AgentTypeMigrationTests`. All 10 existing unit tests must pass.
- **Snapshot migration (MATM-010..012)**: Add a new test file `WorkspaceStoreMigrationTests.swift` in the same SwiftPM target (or an assisted manual run) — load the captured v3 fixture via `WorkspaceStore.load(from:)`, assert that every `Conversation.agent` decoded correctly and that re-saving produces `version: 4`.
- **Smoke (MATM-013..014)**: Manual — copy v3 `workspaces.json` next to v4 build's container, launch app, assert all conversations open and resume.

## Test Cases

### AgentType wire contract (unit tests)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MATM-001 | `JSONDecoder().decode(AgentType.self, from: "\"shell\"".utf8)` | Decodes to `.shell` | P0 | Yes |
| ST-Q-MATM-002 | Decode `"claude"` | Decodes to `.claw("claude")` | P0 | Yes |
| ST-Q-MATM-003 | Decode `"codex"` | Decodes to `.claw("codex")` | P0 | Yes |
| ST-Q-MATM-004 | Decode `"hermes"` | Decodes to `.claw("hermes")` | P0 | Yes |
| ST-Q-MATM-005 | Decode `"picoclaw"` (unknown) | Decodes to `.claw("picoclaw")` — preserves unknown name | P0 | Yes |
| ST-Q-MATM-006 | `JSONEncoder().encode(.shell)` | Emits `"shell"` (bare string, not object) | P0 | Yes |
| ST-Q-MATM-007 | `JSONEncoder().encode(.claw("claude"))` | Emits `"claude"` (bare string) | P0 | Yes |
| ST-Q-MATM-008 | Round-trip every case in `AgentType.canonicalCases` | `decode(encode(x)) == x` for shell, claude, codex, hermes | P0 | Yes |
| ST-Q-MATM-009 | `AgentType.shell.displayName == "shell"`; `.claw("codex").displayName == "codex"`; `.rawValue` mirrors `.displayName` | Exact match | P1 | Yes |

### Snapshot migration v3 → v4 (file-level)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MATM-010 | Decode a real v3 `Snapshot` (captured from main) via `WorkspaceStore.load()` | Decoder succeeds. `Snapshot.version` read as 3, `conversations` decoded into v4 `Conversation` with `agent = .claw(rawLegacy)` or `.shell`. No data loss | P0 | Yes |
| ST-Q-MATM-011 | After MATM-010, call `WorkspaceStore.save()` | On-disk JSON shows `"version": 4`. All `Conversation.agent` fields encoded as bare strings (shell or claw-name). No `ConversationV3` artifacts remain | P0 | Yes |
| ST-Q-MATM-012 | Re-open the just-saved v4 file | Decodes without invoking the v3→v4 migrator. `version: 4` code path runs. All workspaces identical to post-MATM-010 state | P1 | Yes |

### End-to-end smoke (disk → UI)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MATM-013 | Put v3 `workspaces.json` in the app container. Launch v4 build. Open each workspace | Every Conversation resumes with the correct agent badge. Panes bind to the right PTY or mirror session. No "unknown agent" UI | P0 | Manual |
| ST-Q-MATM-014 | After MATM-013, create a NEW conversation with `.claw("picoclaw")`. Quit. Relaunch | New conversation persists via bare string `"picoclaw"`. Round-trips without error even though `"picoclaw"` was never in the legacy enum | P1 | Manual |

## Invariants (fuzz / regression)

These are not step-by-step test cases but MUST hold for any change to `AgentType` or `WorkspaceStore.Snapshot`:

1. **Bare-string wire format.** `AgentType` is always encoded as a JSON string, never an object. Any diff that introduces `encode(to:)` with `KeyedContainer` is a P0 regression.
2. **No instanceId on AgentType.** `AgentType` never gains an associated value beyond `String`. Instance binding lives exclusively in `CommanderState.mirror(instanceID:)` (on `Conversation.commander`).
3. **canonicalCases stability.** `AgentType.canonicalCases` is used by `NewConversationSheetController` during transition and by tests. Removing elements from it requires updating every caller in a single PR.
4. **Snapshot version monotonic.** `WorkspaceStore.Snapshot.version` only increases. v4 code MUST read v3 cleanly. Any new version bump (v4 → v5) must have its own migration test file.

## Out of Scope
- Cross-server sync of AgentType (not persisted to server; backend doesn't know about the picker's `AgentType`).
- iOS `Conversation` shape (iOS doesn't use `AgentType` in this form — the picker is macOS-only).

## Related code
- `TerminalApp/SoyehtMac/Model/AgentType.swift` — the reshape
- `TerminalApp/SoyehtMac/Model/Conversation.swift` — shows `agent: AgentType` (identity) + `commander: CommanderState` (attachment) separation
- `TerminalApp/SoyehtMac/Store/WorkspaceStore.swift` — `Snapshot` with `version`; `load()` performs v3 → v4 migration
- `TerminalApp/SoyehtMacTests/Tests/AgentTypeMigrationTests.swift` — 10 unit tests covering MATM-001..009
- (Needed follow-up) `TerminalApp/SoyehtMacTests/Tests/WorkspaceStoreMigrationTests.swift` — to cover MATM-010..012 as automated tests instead of manual
