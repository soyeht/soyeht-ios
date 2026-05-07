Soyeht
======

Soyeht is an iOS terminal client for [theyOS](https://soyeht.com) servers. It lets you manage remote AI coding agents (Claude Code, Codex, OpenCode) and containerized instances directly from your iPhone.

Built on top of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), a production-grade VT100/Xterm terminal emulator used in apps like Secure Shellfish, La Terminal, and CodeEdit.

## Licensing

This repository is a **mixed-license distribution**:

- The code forked from [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (under `Sources/SwiftTerm/`, `Sources/SwiftTermFuzz/`, `Sources/CaptureOutput/`, `Sources/AsciicastLib/`, `Sources/Termcast/`, `Benchmarks/`), **plus any file whose header comment references Miguel de Icaza**, is licensed under **MIT**. The canonical license text is preserved at `Sources/SwiftTerm/LICENSE`.
- All other files (Soyeht app code, QA tooling, documentation) are licensed under **Apache License 2.0** — see `LICENSE` and `NOTICE`.

When in doubt about a file's license, check its header comment.

## Features

### Terminal
- Full VT100/Xterm terminal emulation with GPU-accelerated Metal rendering
- WebSocket connection to theyOS servers with auto-reconnect
- SSH support via swift-nio-ssh
- Unicode, emoji, TrueColor (24-bit), and graphics (Sixel, iTerm2, Kitty)
- Hyperlink detection in terminal output
- Search within terminal history
- 15 color themes, configurable cursor styles, and font sizes

### Claw Marketplace
- Browse and install "claws" — AI assistant applications that run inside VMs on theyOS servers
- Deploy instances with configurable resources (CPU, RAM, disk)
- Real-time deployment status with Dynamic Island Live Activity
- Assign instances to other users via invite links

### Server Management
- QR code pairing for first-owner households (`soyeht://household/pair-device`) and legacy server links (`theyos://pair`)
- **Machine join** — same QR scanner also handles `soyeht://household/pair-machine` URIs to authorize a new machine into an existing household; locally-verifying parser (FR-029) rejects tampered URIs with no network call. Same-LAN candidates flow through the Bonjour-shortcut owner-events long-poll instead of a QR. Confirmation card shows a 6-word BIP-39 anti-phishing fingerprint and is biometric-gated; membership updates are gossip-driven (no polling, no new top-level screens). See [`specs/003-machine-join/`](specs/003-machine-join/).
- Multi-server support with per-server session tokens (Keychain)
- Instance lifecycle: start, stop, restart, delete
- Workspace (tmux session) management: create, rename, switch, delete
- Tmux window and pane navigation

### Mobile-First UX
- Voice input with real-time transcription and waveform visualization
- Customizable shortcut bar for frequent commands
- Zone-based haptic feedback
- File attachments: photos, camera, documents, location sharing with upload to container
- Deep link handling (`soyeht://household/pair-device`, `theyos://pair`, `theyos://connect`, `theyos://invite`)

## Architecture

```
TerminalApp/
  Soyeht/                  # iOS app (SwiftUI + UIKit)
    SessionStore.swift      # Auth state, server list, navigation
    SoyehtAPIClient.swift   # REST API client (instances, workspaces, claws, users)
    WebSocketTerminalView   # WebSocket terminal connection with state machine
    QRScannerView           # QR pairing camera view, including household pair-device links
    ClawStore/              # Marketplace UI (browse, detail, setup, deploy)
    Settings/               # Appearance, haptics, shortcuts
    Voice/                  # Speech recognition input
    Attachment/             # File picker and upload
  SoyehtTests/              # Unit tests
  SoyehtLiveActivity/       # Dynamic Island widget

Sources/
  SwiftTerm/                # Terminal emulator engine (forked from SwiftTerm)
    Apple/                  # Shared AppKit/UIKit code + Metal renderer
    iOS/                    # iOS-specific TerminalView
    Mac/                    # macOS-specific TerminalView
```

## Requirements

- iOS 14+
- Xcode 15+
- A theyOS server to connect to

## Building

Open `TerminalApp/Soyeht.xcodeproj` in Xcode and build the `Soyeht` target.

The project uses Swift Package Manager for dependencies:
- [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) — SSH protocol
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI tools

## MCP Integration

Soyeht ships with a [Model Context Protocol](https://modelcontextprotocol.io) server at `scripts/soyeht-mcp` that lets AI coding agents drive Soyeht workspaces — opening panes/tabs, arranging layouts, creating git-worktree panes, sending input to live agents, racing multiple agents in parallel, etc.

The server is a Python 3.9+ stdio script with no third-party dependencies. It targets a running Soyeht (macOS) instance through the Soyeht automation directory.

Install the stable launcher once from this repository:

```bash
scripts/install-soyeht-mcp
```

This creates `~/.local/bin/soyeht-mcp` outside any git worktree. When launched from a Soyeht checkout or worktree, it uses that checkout's `scripts/soyeht-mcp`; otherwise it falls back to the main checkout for the clone where you ran the installer.

### Claude Code

```bash
claude mcp add --scope user soyeht ~/.local/bin/soyeht-mcp
claude mcp get soyeht        # expect: Status: ✓ Connected
```

`--scope user` registers the server for every project on this machine. Use `--scope project` instead to write a `.mcp.json` you can commit and share with your team.

### Codex

```bash
codex mcp add soyeht -- ~/.local/bin/soyeht-mcp
```

Verify:

```bash
codex mcp list               # expect: soyeht ... Status: enabled
```

### OpenCode

Add to the `mcp` map in `~/.config/opencode/opencode.json` (global) — or to an `opencode.json` at the project root for a single-project install. Use the absolute path printed by the installer:

```json
{
  "mcp": {
    "soyeht": {
      "type": "local",
      "command": ["/Users/you/.local/bin/soyeht-mcp"],
      "enabled": true
    }
  }
}
```

Verify:

```bash
opencode mcp list            # expect: soyeht ✓ connected
```

### Droid

```bash
droid mcp add soyeht ~/.local/bin/soyeht-mcp
```

### What the server exposes

- `open_panes`, `open_shell`, `open_file` — open panes/tabs in the active workspace
- `open_workspace`, `create_worktree_panes`, `agent_race_panes` — new workspaces, worktree-backed panes, or one pane per agent (codex/claude/opencode)
- `send_pane_input`, `rename_panes`, `rename_workspace` — drive live panes and workspaces
- `arrange_panes`, `emphasize_pane` — layout (stack/row/grid) and spotlight/zoom

## Terminal Engine

The embedded SwiftTerm library provides the terminal emulation core. See the [SwiftTerm documentation](https://migueldeicaza.github.io/SwiftTerm/documentation/swiftterm/) for the engine API.

Key capabilities:
- VT100/Xterm-compatible emulation with comprehensive escape sequence support
- Thread-safe Terminal instances
- Pluggable delegate model (`TerminalViewDelegate`) for custom connection backends
- Session recording and playback in asciinema `.cast` format
- Extensively tested with [esctest](https://github.com/migueldeicaza/esctest) and fuzz testing
