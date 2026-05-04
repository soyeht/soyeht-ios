# Soyeht MCP Automation Report

Date: 2026-05-04

Domain plan: [Soyeht MCP Automation](../../domains/soyeht-mcp-automation.md)

This dated QA report captures the executed behavior for the Soyeht automation
MCP. The test run uses an isolated Soyeht app environment with temporary
repositories, worktrees, and pane loggers so it does not mutate the user's
normal workspace state.

Run result: 20/20 PASS.

Notes:

- macOS canonicalizes `/tmp/...` to `/private/tmp/...` inside PTYs; path checks
  compare the canonical cwd.
- Agent-driven isolated tests pass `automationDir` explicitly in tool arguments
  when needed because MCP subprocess environment inheritance is
  client-dependent.

| ID | Use case | Driver | Expected result | Status | Observed |
| --- | --- | --- | --- | --- | --- |
| UC-01 | MCP protocol initializes over newline-delimited JSON-RPC. | Direct MCP | `initialize` returns server info and tool capability. | PASS | `serverInfo.name=soyeht-automation`, tools capability present. |
| UC-02 | MCP protocol initializes over `Content-Length` framed JSON-RPC. | Direct MCP | `initialize` response uses the same framed transport. | PASS | Response returned `Content-Length: 173`. |
| UC-03 | MCP lists all automation tools. | Direct MCP | Tool list includes `open_workspace`, `open_panes`, `open_shell`, `open_file`, `create_worktree_panes`, `agent_race_panes`, `send_pane_input`, `rename_panes`, `rename_workspace`, `arrange_panes`, and `emphasize_pane`. | PASS | All eleven expected tools listed. |
| UC-04 | Create a new workspace with one shell pane. | Direct MCP `open_workspace` | One workspace and one pane are created; shell runs in requested directory. | PASS | Shell logger reported ready in canonical cwd. |
| UC-05 | Create a new workspace with four shell panes. | Direct MCP `open_workspace` | One workspace is created; all four panes share the same workspace id and each shell cwd matches its requested directory. | PASS | Four shell loggers ready; all returned panes shared one workspace id. |
| UC-06 | Send input to one pane by `conversationID`. | Direct MCP `send_pane_input` | Only that pane receives the message. | PASS | Target count `[1, 0, 0, 0]`. |
| UC-07 | Send input to multiple panes by `conversationID`. | Direct MCP `send_pane_input` | All targeted panes receive the same message exactly once. | PASS | Target counts `[1, 1, 1, 1]`. |
| UC-08 | Send input to one pane by handle. | Direct MCP `send_pane_input` | The pane with the requested handle receives the message. | PASS | `shell-2` received it; sibling counts `[0, 1, 0, 0]`. |
| UC-09 | Send raw input without appending a newline. | Direct MCP `send_pane_input` | Target receives bytes even when `appendNewline=false`. | PASS | Raw logger recorded `RAW:abcde`. |
| UC-10 | Open additional panes inside the active workspace. | Direct MCP `open_panes` | New panes are added to the current workspace instead of creating another workspace. | PASS | Returned workspace id matched the active four-pane workspace. |
| UC-11 | Create git worktrees as panes in the active workspace. | Direct MCP `create_worktree_panes` | Worktree directories and branches are created; panes open in those directories. | PASS | Two worktree panes created; `.git` files and branches present. |
| UC-12 | Open Codex, Claude Code, and OpenCode in separate worktree panes. | Direct MCP `agent_race_panes` | Three panes start real `codex`, `claude`, and `opencode` processes with cwd set to their worktrees. | PASS | Process tree showed all three agents with cwd in `race-*` worktrees. |
| UC-13 | CLI creates a new workspace with multiple shell panes. | `scripts/soyeht workspace-panes` | CLI queues `create_workspace_panes`; app returns one workspace and N panes. | PASS | CLI returned two pane `conversationID`s and both loggers were ready. |
| UC-14 | CLI sends input to a pane by `conversationID`. | `scripts/soyeht send-pane-input` | Target pane receives the CLI message. | PASS | CLI returned `sent pane @shell`; target logger received `UC14_CLI`. |
| UC-15 | Invalid directory fails cleanly. | Direct MCP `open_workspace` | Tool returns `isError=true`; app does not create panes for the invalid path. | PASS | Tool returned `Directory does not exist`. |
| UC-16 | Empty send target fails cleanly. | Direct MCP `send_pane_input` | Tool returns `isError=true` with no pane mutation. | PASS | Tool returned `No pane input targets were provided.` |
| UC-17 | Codex agent sends a message to another Soyeht pane. | `codex exec` using MCP | Codex calls `send_pane_input`; the target pane log receives the message. | PASS | Codex logged `soyeht/send_pane_input (completed)` and target received `UC17_CODEX_AGENT_EXTERNAL`. |
| UC-18 | Codex agent creates a new Soyeht workspace with two shell panes. | `codex exec` using MCP | Codex calls `open_workspace`; both pane loggers report ready in their requested directories. | PASS | Codex logged `soyeht/open_workspace (completed)`; both loggers ready. |
| UC-19 | Codex agent sends follow-up input to panes it created. | `codex exec` using MCP | Codex uses returned `conversationID`s and both created panes receive the follow-up. | PASS | Codex logged `soyeht/send_pane_input (completed)`; both created panes received `UC19_CODEX_CREATED`. |
| UC-20 | App UI reflects the automation result. | Accessibility snapshot | Soyeht shows the created workspace tab and expected pane handles. | PASS | AX snapshot showed `Single Shell Lab`, `Four Shell Lab`, `CLI Lab`, `Codex Created Lab`, and active `shell`/`shell-2` panes. |

## Regression Checks: Names And Input Terminators

Date: 2026-05-04

Run result: 18/18 PASS.

| ID | Use case | Driver | Expected result | Status | Observed |
| --- | --- | --- | --- | --- | --- |
| RG-01 | MCP protocol still initializes after adding rename tools. | Direct MCP | `serverInfo.name=soyeht-automation`. | PASS | Server initialized. |
| RG-02 | Workspace creation applies default workspace naming. | Direct MCP `open_workspace` | Long workspace name becomes a short space name. | PASS | `Investigate Checkout Login Regression` became `Investigate Checkout`. |
| RG-03 | Pane creation applies default pane/tab naming. | Direct MCP `open_workspace` | Long pane name becomes a short hyphen name. | PASS | `Fix Checkout Login` became `Fix-Checkout` with handle `@fix-checkout`. |
| RG-04 | Additional pane creation keeps short hyphen names. | Direct MCP `open_workspace` | Another long pane name is shortened consistently. | PASS | `Long Pane Name With Spaces` became `Long-Pane` with handle `@long-pane`. |
| RG-05 | Workspace rename defaults to short space names. | Direct MCP `rename_workspace` | Long rename is shortened to one or two words. | PASS | `Workspace Name With Many Words` became `Workspace Name`. |
| RG-06 | Workspace rename can preserve an exact requested name. | Direct MCP `rename_workspace` with `workspaceNameStyle=verbatim` | Exact text is stored. | PASS | Stored `Exact Workspace Name With Spaces`. |
| RG-07 | Workspace rename can use explicit hyphen style when requested. | Direct MCP `rename_workspace` with `workspaceNameStyle=hyphen` | Workspace name uses hyphen separator. | PASS | `Explicit Hyphen Workspace` became `Explicit-Hyphen`. |
| RG-08 | Pane rename defaults to short hyphen names. | Direct MCP `rename_panes` | Long rename becomes a short hyphen handle. | PASS | `Review Payment Failure` became `@review-payment`. |
| RG-09 | Pane rename can use explicit spaces when requested. | Direct MCP `rename_panes` with `paneNameStyle=space` | Handle preserves spaces. | PASS | `Manual Space Name` became `@manual space`. |
| RG-10 | Default `send_pane_input` submits a shell command. | Direct MCP `send_pane_input` | Shell `read` receives the submitted line. | PASS | Logger recorded `LINE:DEFAULT_ENTER`. |
| RG-11 | Raw TUI-style reader starts for Enter probe. | Direct MCP `open_panes` | Probe reports ready. | PASS | `READY` logged. |
| RG-12 | Default/`enter` input sends terminal Enter. | Direct MCP `send_pane_input` with `lineEnding=enter` | PTY receives CR (`0d`). | PASS | Raw bytes `48454c4c4f0d`. |
| RG-13 | Raw TUI-style reader starts for newline probe. | Direct MCP `open_panes` | Probe reports ready. | PASS | `READY` logged. |
| RG-14 | Explicit `newline` input sends LF. | Direct MCP `send_pane_input` with `lineEnding=newline` | PTY receives LF (`0a`). | PASS | Raw bytes `48454c4c4f0a`. |
| RG-15 | Raw TUI-style reader starts for no-terminator probe. | Direct MCP `open_panes` | Probe reports ready. | PASS | `READY` logged. |
| RG-16 | Explicit `none` input sends no terminator. | Direct MCP `send_pane_input` with `lineEnding=none` | PTY receives only payload bytes. | PASS | Raw bytes `48454c4c4f`. |
| RG-17 | CLI exposes pane rename command. | `scripts/soyeht rename-pane --help` | Help includes name-style options. | PASS | `--pane-name-style` listed. |
| RG-18 | CLI exposes workspace rename command. | `scripts/soyeht rename-workspace --help` | Help includes workspace-name-style options. | PASS | `--workspace-name-style` listed. |

## Regression Checks: Shell And File Opening Intents

Date: 2026-05-04

Run result: 26/26 PASS.

| ID | Use case | Driver | Expected result | Status | Observed |
| --- | --- | --- | --- | --- | --- |
| SH-01 | MCP initializes with shell/file tools available. | Direct MCP | Server initializes and lists the new tools. | PASS | `open_shell`, `open_file`, `open_panes`, `send_pane_input`, `rename_panes`, and `rename_workspace` listed. |
| SH-02 | Tool descriptions steer "new shell/terminal/tab/pane" requests to Soyeht. | Direct MCP `tools/list` | `open_shell` description mentions avoiding Terminal.app/osascript. | PASS | Description includes both terms. |
| SH-03 | Tool descriptions steer "random file in vim in new shell" requests to Soyeht. | Direct MCP `tools/list` | `open_file` description mentions random file, vim, and new Soyeht shell. | PASS | All terms present. |
| SH-04 | Open a plain shell pane without sending a bogus `shell` command. | Direct MCP `open_shell` | Pane opens and accepts a follow-up shell command. | PASS | `pwd` written by follow-up matched requested cwd. |
| SH-05 | Open a shell pane and run an initial command. | Direct MCP `open_shell` | Command executes in the requested cwd. | PASS | Logger recorded `COMMAND_OK`. |
| SH-06 | Open a random file in vim inside a Soyeht pane. | Direct MCP `open_file` | Tool selects a matching file and starts `vim` in a new pane. | PASS | Selected `alpha.md`; process list showed `vim` with that file. |
| SH-07 | Existing naming behavior still holds. | Direct MCP `open_workspace` | Workspace uses short space name; panes use short hyphen handles. | PASS | `Investigate Checkout`, `@fix-checkout`, and `@long-pane`. |
| SH-08 | Existing rename behavior still holds. | Direct MCP `rename_workspace`/`rename_panes` | Workspace verbatim rename and pane short-hyphen rename work. | PASS | Stored exact workspace name and `@review-payment`. |
| SH-09 | Existing Enter behavior still holds. | Direct MCP `send_pane_input` | Default Enter submits a shell line. | PASS | Logger recorded `LINE:DEFAULT_ENTER`. |
| SH-10 | Existing line-ending byte behavior still holds. | Direct MCP `send_pane_input` | `enter`, `newline`, and `none` produce expected bytes. | PASS | `0d`, `0a`, and no terminator verified with raw PTY readers. |

## Regression Checks: Pane Layout Automation

Date: 2026-05-04

Run result: 20/20 PASS.

| ID | Use case | Driver | Expected result | Status | Observed |
| --- | --- | --- | --- | --- | --- |
| LA-01 | MCP exposes the layout tools. | Direct MCP `tools/list` | `arrange_panes` and `emphasize_pane` are listed with the existing pane tools. | PASS | Both tools listed by the stdio MCP server. |
| LA-02 | Create a four-pane layout test workspace. | Direct MCP `open_workspace` | Four shell panes are created in one workspace. | PASS | All four returned panes shared one workspace id. |
| LA-03 | Stack all panes. | Direct MCP `arrange_panes layout=stack` | Panes are persisted top-to-bottom with horizontal split axes. | PASS | Workspace layout leaf order matched the requested IDs. |
| LA-04 | Put all panes side-by-side. | Direct MCP `arrange_panes layout=row` | Panes are persisted with vertical split axes. | PASS | Layout contained only vertical split axes. |
| LA-05 | Tile all panes. | Direct MCP `arrange_panes layout=grid` | Layout alternates axes into a balanced grid. | PASS | Root split was vertical and child splits included horizontal axes. |
| LA-06 | Spotlight a pane on the left. | Direct MCP `emphasize_pane` | Target pane is the left child and receives the requested share. | PASS | Ratio persisted at `0.70`; siblings stayed visible. |
| LA-07 | Spotlight a pane on the right. | Direct MCP `emphasize_pane` | Target pane is the right child. | PASS | Root ratio persisted as `1 - targetRatio`. |
| LA-08 | Spotlight a pane on top. | Direct MCP `emphasize_pane` | Target pane is the top child. | PASS | Root split axis became horizontal with target first. |
| LA-09 | Spotlight a pane on bottom. | Direct MCP `emphasize_pane` | Target pane is the bottom child. | PASS | Root split axis became horizontal with target second. |
| LA-10 | Rearrange selected panes only. | Direct MCP `arrange_panes` with three IDs from a four-pane workspace | Selected panes are grouped and remaining panes stay visible. | PASS | Selected group stacked at requested ratio; fourth pane remained. |
| LA-11 | Preserve handle order. | Direct MCP `arrange_panes` with handles out of visual order | Group order follows the requested handle order. | PASS | Persisted leaf order matched `@e3`, `@e1`, `@e2`. |
| LA-12 | Default target behavior. | Direct MCP `arrange_panes` with no IDs/handles | All panes in the active workspace are arranged. | PASS | Active workspace became a stack. |
| LA-13 | Zoom a pane. | Direct MCP `emphasize_pane mode=zoom` | Tool succeeds without mutating the persisted split tree. | PASS | Response returned `mode=zoom`. |
| LA-14 | Unzoom a pane. | Direct MCP `emphasize_pane mode=unzoom` | Tool succeeds and restores split rendering. | PASS | Response returned `mode=unzoom`. |
| LA-15 | Invalid layout fails cleanly. | Direct MCP `arrange_panes layout=diagonal` | Tool returns `isError=true`. | PASS | Error text included `Unsupported pane layout`. |
| LA-16 | CLI can create panes for layout testing. | `scripts/soyeht workspace-panes` | CLI opens a workspace with shell panes. | PASS | `CLI Layout` persisted with three panes. |
| LA-17 | CLI can arrange panes. | `scripts/soyeht arrange-panes` | Active workspace layout changes. | PASS | `CLI Layout` became a side-by-side row. |
| LA-18 | CLI can spotlight by handle. | `scripts/soyeht emphasize-pane` | Requested handle becomes prominent. | PASS | `@cli1` persisted as the top spotlight pane. |
| LA-19 | Codex can drive layout through MCP. | `codex exec` using Soyeht MCP | Agent calls `open_workspace`, `arrange_panes`, and `emphasize_pane`. | PASS | `Agent Layout` persisted with `@agent2` spotlighted left at `0.68`. |
| LA-20 | Claude Code and OpenCode can drive layout through MCP. | `claude -p` and `opencode run` using Soyeht MCP | Each agent creates panes, arranges them, and spotlights a target. | PASS | `Claude Layout` persisted bottom spotlight for `@claude3`; `OpenCode Layout` persisted right spotlight for `@open1`. |
