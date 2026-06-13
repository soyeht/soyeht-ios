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

The macOS onboarding does the same setup automatically. It looks for agent CLIs
through the login shell and common GUI-missing paths such as `~/.local/bin`,
`/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`. If the onboarding misses
an agent, use the manual commands below.

For the shipping app, the automation directory is:

```bash
export SOYEHT_AUTOMATION_DIR="$HOME/Library/Application Support/Soyeht/Automation"
```

For `Soyeht Dev.app`, use:

```bash
export SOYEHT_AUTOMATION_DIR="$HOME/Library/Application Support/Soyeht Dev/Automation"
```

### Claude Code

Claude Code user-scoped MCP servers are stored in `~/.claude.json`; project-scoped
servers are stored in `.mcp.json`. Prefer the official CLI command instead of
editing `~/.claude.json` by hand:

```bash
claude mcp add-json --scope user soyeht "{\"type\":\"stdio\",\"command\":\"$HOME/.local/bin/soyeht-mcp\",\"args\":[],\"env\":{\"SOYEHT_AUTOMATION_DIR\":\"$SOYEHT_AUTOMATION_DIR\"}}"
claude mcp get soyeht        # expect: Status: ✓ Connected
```

`--scope user` registers the server for every project on this machine. Use `--scope project` instead to write a `.mcp.json` you can commit and share with your team.

### Codex

```bash
codex mcp add soyeht --env SOYEHT_AUTOMATION_DIR="$SOYEHT_AUTOMATION_DIR" -- ~/.local/bin/soyeht-mcp
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
      "environment": {
        "SOYEHT_AUTOMATION_DIR": "/Users/you/Library/Application Support/Soyeht/Automation"
      },
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

Factory Droid stores user MCP servers in `~/.factory/mcp.json`. The CLI creates
the same shape that Soyeht writes:

```bash
droid mcp add soyeht ~/.local/bin/soyeht-mcp --type stdio --env SOYEHT_AUTOMATION_DIR="$SOYEHT_AUTOMATION_DIR"
```

### If an agent is not recognized

Ask an agent on that Mac to run this read-only diagnostic before changing any
configuration:

```text
Você está no meu MacBook. Não altere arquivos ainda.

Quero saber se o MCP do Soyeht vai funcionar antes de eu tentar reinstalar.
Faça uma auditoria somente leitura e responda em português:

1. Mostre se estes CLIs existem e onde estão: claude, codex, opencode, droid.
   Use command -v e também cheque estes caminhos: ~/.local/bin, /opt/homebrew/bin,
   /usr/local/bin e /usr/bin.
2. Verifique se ~/.local/bin/soyeht-mcp existe e é executável.
3. Verifique, sem imprimir segredos, se o servidor "soyeht" está configurado em:
   - Claude Code: claude mcp get soyeht, e se necessário confirme ~/.claude.json.
   - Codex: ~/.codex/config.toml, seção [mcp_servers.soyeht].
   - OpenCode: ~/.config/opencode/opencode.json, chave mcp.soyeht.
   - Droid: ~/.factory/mcp.json, chave mcpServers.soyeht.
4. Para cada um, diga se command aponta para ~/.local/bin/soyeht-mcp e se
   SOYEHT_AUTOMATION_DIR aponta para:
   ~/Library/Application Support/Soyeht/Automation
5. Não edite nada. Termine com "OK PARA INSTALAR" ou "NAO INSTALAR AINDA" e liste
   exatamente o que está faltando.
```

Useful official references:

- Claude Code MCP quickstart: <https://code.claude.com/docs/en/mcp-quickstart>
- Claude Code settings and config locations: <https://docs.anthropic.com/en/docs/claude-code/settings>
- Codex MCP configuration: <https://developers.openai.com/codex/mcp>
- OpenCode config locations and MCP schema: <https://opencode.ai/docs/config/>
- Factory Droid MCP configuration: <https://docs.factory.ai/cli/configuration/mcp>

### What the server exposes

- `open_panes`, `open_shell`, `open_file` — open panes/tabs in the active workspace
- `open_workspace`, `create_worktree_panes`, `agent_race_panes` — new workspaces, worktree-backed panes, or one pane per agent (codex/claude/opencode)
- `send_pane_input`, `capture_pane`, `capture_pane_range`, `rename_panes`, `rename_workspace` — drive and read live panes and workspaces
- `arrange_panes`, `emphasize_pane`, `resize_pane_exact`, `set_pane_zoom` — layout, exact pane share, spotlight, and zoom
- `set_pane_font_size`, `scroll_pane` — adjust terminal readability and scroll panes without UI automation

## Terminal Engine

The embedded SwiftTerm library provides the terminal emulation core. See the [SwiftTerm documentation](https://migueldeicaza.github.io/SwiftTerm/documentation/swiftterm/) for the engine API.

Key capabilities:
- VT100/Xterm-compatible emulation with comprehensive escape sequence support
- Thread-safe Terminal instances
- Pluggable delegate model (`TerminalViewDelegate`) for custom connection backends
- Session recording and playback in asciinema `.cast` format
- Extensively tested with [esctest](https://github.com/migueldeicaza/esctest) and fuzz testing
