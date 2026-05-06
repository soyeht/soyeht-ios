# macOS Conversations Sidebar Collapse — 2026-05-05

## Scope

Regression coverage for `ST-Q-WPL-065`: collapsing a workspace in the
macOS conversations sidebar must remove child pane rows from layout, not just
hide their labels.

## App Build

- Built from this worktree with:
  `xcodebuild -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac -configuration Debug -derivedDataPath /tmp/soyeht-dev-fresh-validate clean build CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO`
- Rebuilt/reinstalled again after Screen Recording prompts exposed a broken
  linker-signed install. The current `/Applications/Soyeht Dev.app` is a full
  Xcode "Sign to Run Locally" bundle with `Identifier=com.soyeht.mac.dev`,
  sealed resources, and debug entitlements applied.
- Installed app: `/Applications/Soyeht Dev.app`
- Bundle id: `com.soyeht.mac.dev`
- Confirmed running executable:
  `/Applications/Soyeht Dev.app/Contents/MacOS/Soyeht Dev`
- Confirmed old dev copies removed from common launch locations:
  `find /Applications "$HOME/Applications" /tmp /private/tmp "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 7 -name 'Soyeht Dev.app'`
  returned only `/Applications/Soyeht Dev.app`.
- Official app was not modified: `/Applications/Soyeht.app` remains bundle id
  `com.soyeht.mac`.

## Automated Checks

| Check | Result | Notes |
|-------|--------|-------|
| `swift test` from `TerminalApp/SoyehtMacTests` | PASS | 238 tests, 0 failures. Existing warnings only. |
| `xcodebuild ... build` with `/tmp/soyeht-mac-sidebar-dd` | PASS | Build succeeded before installation. |
| `xcodebuild ... clean build` with `/tmp/soyeht-dev-fresh-validate` | PASS | Initial fresh build used for `/Applications/Soyeht Dev.app`. |
| `xcodebuild ... clean build` with `/tmp/soyeht-dev-bundle-signed` | PASS | Reinstalled over `/Applications/Soyeht Dev.app` to replace the linker-signed copy with a full signed bundle. |
| `xcodebuild ... clean build` with `/tmp/soyeht-dev-hitfix` | PASS | Final build installed after fixing sidebar cursor/hit-test behavior. |

## MCP / App Tooling

| Tool | Result | Evidence |
|------|--------|----------|
| `mcp__soyeht__.list_workspaces` | PASS | Active workspace `Testes MCP` had `paneCount: 5`, with additional workspaces `Workspace 2` and `Workspace 3`, satisfying the 2+ panes precondition. |
| `mcp__soyeht__.list_panes` | PASS | Active workspace exposed 5 panes including `@workspace-collapse`, `@mcp-window`, `@even-pane`, `@shell`, and `@shell-4`. |
| `mcp__native_devtools__.launch_app` by app name | NOT USED FOR FINAL VALIDATION | Name-based launch was abandoned because LaunchServices had stale/duplicate dev app state. Final launch used absolute path. |
| `mcp__native_devtools__.list_windows` + `ps` | PASS | Confirmed pid `67352` running from `/Applications/Soyeht Dev.app/Contents/MacOS/Soyeht Dev`. |
| `mcp__native_devtools__.take_ax_snapshot` | BLOCKED | Returned only `uid=1 unknown`; Accessibility tree was not available to the tool. |
| `mcp__native_devtools__.take_screenshot` | BLOCKED | Failed with `Window not found` / screen capture failure. |
| `screencapture -x` | BLOCKED | Failed both sandboxed and escalated with `could not create image from display`. |

### Screen Recording Note

The repeated macOS Screen Recording prompt was attributed by macOS to the
host app named `Soyeht`, not to the sidebar code itself. Inspection showed the
official `/Applications/Soyeht.app` is signed ad-hoc (`Identifier=com.soyeht.mac`,
`Signature=adhoc`, no `TeamIdentifier`). Screen Recording permissions can be
invalidated when an ad-hoc-signed app binary changes, and changes to Screen
Recording permission generally require quitting and reopening the host app
before capture APIs stop prompting. The official app was inspected only, not
modified.

## Manual Visual Rerun

Because Screen Recording/Accessibility remained unavailable to the tool, the
final visual check was completed manually by the user on the installed dev app:

1. Open `/Applications/Soyeht Dev.app`.
2. Confirm the running app is the dev build (`Activity Monitor` path or `ps`
   should show `/Applications/Soyeht Dev.app/Contents/MacOS/Soyeht Dev`).
3. Open the conversations sidebar with the top-left conversations button or
   `Command-Shift-C`.
4. Use a workspace with at least 2 visible panes, e.g. `Testes MCP` with
   5 panes.
5. Note the vertical position of the next workspace header before collapse.
6. Click the workspace chevron to collapse.
7. Expected: child pane names disappear and the next workspace header moves
   immediately under the collapsed workspace header; no blank height equal to
   the hidden pane rows remains.
8. Click the chevron again.
9. Expected: all pane rows return in the previous order, including selected
   row/focus styling and badges.

Manual result: PASS. The user confirmed workspace collapse/expand works after
the layout fix, then confirmed the follow-up cursor/hit-test fix after the
header stopped leaking clicks to the underlying pane.

## Verdict

Code/build/test checks are green. MCP screenshot capture remained blocked by
local macOS Screen Recording/Accessibility access, but `ST-Q-WPL-065` and the
follow-up cursor/hit-test behavior in `ST-Q-WPL-066` were validated manually on
the installed macOS dev app.
