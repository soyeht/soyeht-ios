# MCP 2.0 agent launch contract

`open_agent_pane` is the unambiguous API for launching one requested coding
agent. It does not silently substitute another agent. Legacy pane-opening tools
remain available.

## Catalog

| `agentID` | Expected executable |
| --- | --- |
| `claude` | `claude` |
| `codex` | `codex` |
| `opencode` | `opencode` |
| `qwen` | `qwen` |
| `antigravity` | `agy` |
| `pi` | `pi` |
| `droid` | `droid` |
| `kilo` | `kilo` |
| `cursor` | `cursor-agent` |
| `copilot` | `copilot` |
| `grok` | `grok` |
| `kimi` | `kimi` |
| `devin` | `devin` |
| `qoder` | `qodercli` |

Codex defaults to `codex-yolo`, which adds `--yolo`. OpenCode defaults to
`opencode-auto`, which adds `--auto`. Passing `profile=base` disables those
per-agent profile flags. `model` becomes the two argv entries `--model` and the
literal requested model. Additional `args` are literal argv entries and are
shell-quoted when the command string is built.

## Response and proof boundary

The result contains:

- `launchContract.agentID`, `profile`, `model`, `args`, `command`, and
  `expectedArgv`;
- `argvVerification.required=true`;
- `argvVerification.status=unverified`.

`declaredAgent`, the pane title, and the command echoed in automation metadata
are intent evidence only. They are not proof of runtime identity. A launch is
accepted only after observing the live child process argv in Soyeht Dev.

## Required E2E matrix

Run each row in Soyeht Dev with an explicit `workspaceID` and unique pane name.
Capture the pane's live child process, executable path, complete argv, cwd, and
workspace. Close the test pane after the evidence is recorded.

1. Run all 14 base launches (`profile=base`) and verify the executable against
   the catalog above.
2. Run Codex without a profile and verify argv contains exactly one `--yolo`.
3. Run OpenCode without a profile and verify argv contains exactly one `--auto`.
4. Run Codex with `profile=base` and verify `--yolo` is absent.
5. Run OpenCode with `profile=base` and verify `--auto` is absent.
6. For every installed CLI, pass a known supported `model` and verify the exact
   `--model <value>` argv pair. Record a failure instead of treating metadata as
   success when that CLI version does not support the flag.
7. Pass arguments containing spaces and punctuation and verify they arrive as
   single, unchanged argv entries.
8. For every launch, verify both cwd and destination workspace. A correct
   executable in the wrong workspace is a failure.
9. Verify an unknown `agentID`, unknown profile, profile/agent mismatch, and
   conflicting `workspace`/`workspaceID` all fail without opening a pane.
10. Re-run through Codex, Claude Code, and OpenCode MCP clients. The caller's
    interpretation of the request must not change the selected `agentID`.

## Agent directory identity

`list_agents` remains global by default. Its response adds `workspaceGroups`,
puts the caller's workspace first, and marks `sameWorkspace` and
`currentWorkspace` explicitly on groups and agents. Passing `workspaceID` is an
intentional opt-in filter.

Human-readable references use `displayReference`, formatted as `[name]`.
Legacy `@handle` values and conversation UUIDs remain available for routing in
`messageTarget`, but must not be copied into commits, PRs, GitHub comments, or
other prose.
