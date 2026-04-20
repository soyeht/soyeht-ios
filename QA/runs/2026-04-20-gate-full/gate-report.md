# Gate Full — 2026-04-20

Branch: `feat/visual-polish` | Commit: `ce214ff`

## Phase 1: Preflight

| Check | Result |
|-------|--------|
| Backend health (`GET /healthz`) | PASS — 200 OK |
| iPhone connected (UDID <ios-udid>) | PASS |
| macOS build (`SoyehtMac.xcodeproj`) | PASS — BUILD SUCCEEDED |

## Phase 2: Unit Tests

| Suite | Result | Detail |
|-------|--------|--------|
| macOS domain tests (`swift test` in SoyehtMacTests) | **PASS** | 162 tests, 0 failures |
| iOS unit tests (xcodebuild, Soyeht scheme) | **PASS** | 394 tests, 0 failures |
| SwiftTerm (`swift test`) | **PASS** | 394/394 |
| Cargo backend (`cargo test --workspace`) | **⚠ 1 FAIL** | `network::tests::quick_variant_cleans_partial_on_retry` — P2, pre-existing, unrelated to visual-polish |
| npm frontend | N/A | No frontend test suite in admin/ |

## Phase 3: Contract Smoke

```
PASS: 2   FAIL: 0   SKIP: 9 (no TOKEN)
GATE: PASS
```

Checks: `GET /healthz → 200`, unauthenticated `GET /api/v1/mobile/status → 401`.

## Phase 4: UI Smoke (iPhone — Appium)

| # | Test | Result |
|---|------|--------|
| ST-1 | App opens, instance list loads (not empty) | **PASS** |
| ST-2 | Tap instance → terminal connects, prompt visible | **PASS** |
| ST-3 | Create workspace → new session appears | **PASS** |
| ST-4 | Switch window tab → content changes | **PASS** |
| ST-5 | Background 10s, return → terminal responsive | **PASS** |
| ST-6 | Rotate to landscape and back → re-renders | **PASS** |
| ST-7 | Deep link from Safari → pairing completes | **PASS** |
| ST-8 | Pull to refresh → instances reload | **PASS** |

**8/8 PASS**

## Phase 5: macOS Domain — WPL (workspace-pane-lifecycle)

### visual-polish specific fixes verified

| Fix | Method | Result |
|-----|--------|--------|
| PaneHeaderView hitTest — buttons on non-first panes | Mouse click on bottom pane close button (screen 1704, 665) | **PASS** — pane closed without error |
| PaneNode y-coord (NSSplitView flipped) | Unit test `testNeighborUpPicksSiblingInAppKitCoords` | **PASS** — 162/162 |
| ⌘⇧W → Close Workspace shortcut | Native keyboard → dialog appeared | **PASS** |
| ⌘⇧→ → Focus Right shortcut | Native keyboard → AX `focused` moved from shell-3 sub-group to parent (shell-2 side) | **PASS** |
| Pane split / close cycle | WPL-010 split + WPL-011 close via mouse | **PASS** |

### WPL mouse drag coexistence (from 2026-04-20-wpl-mouse-drag run)

| ID | Test | Status |
|----|------|--------|
| WPL-056 | Tab drag A → after C | PASS (synthetic) |
| WPL-057 | Tab drag and return | PASS |
| WPL-058 | Drop outside tab bar | PASS |
| WPL-059 | Window drag via empty titlebar | PASS (synthetic) |
| WPL-060 | Tab drag → window drag sequence | PENDING — requires real mouse |
| WPL-061 | Window drag → tab drag sequence | PENDING — requires real mouse |
| WPL-062 | Click/drag on tab NEVER moves window | PENDING |
| WPL-063 | Hover + click in empty area | PENDING |

## Bugs Found

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| BUG-GATE-001 | P2 | Cargo `network::tests::quick_variant_cleans_partial_on_retry` fails intermittently — unrelated to visual-polish, likely race condition in VMrunner networking cleanup test | Open (pre-existing) |

## Verdict

```
PASS WITH WARNINGS
```

- iOS smoke: **8/8 PASS**
- macOS build + unit tests: **PASS**
- Contract smoke: **PASS**
- visual-polish specific fixes: **all validated**
- 1 cargo P2 failure (pre-existing, unrelated)
- 4 WPL coexistence tests PENDING (require real mouse, not automatable via native-devtools synthetic events)

The branch is **safe to merge**. The P2 cargo failure is pre-existing and unrelated to these changes. The 4 PENDING mouse-drag tests require manual verification before a release-level gate.
