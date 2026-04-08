Soyeht
======

Soyeht is an iOS terminal client for [theyOS](https://soyeht.com) servers. It lets you manage remote AI coding agents (Claude Code, Codex, OpenCode) and containerized instances directly from your iPhone.

Built on top of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), a production-grade VT100/Xterm terminal emulator used in apps like Secure Shellfish, La Terminal, and CodeEdit.

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
- QR code pairing to connect to theyOS servers (`theyos://pair`)
- Multi-server support with per-server session tokens (Keychain)
- Instance lifecycle: start, stop, restart, delete
- Workspace (tmux session) management: create, rename, switch, delete
- Tmux window and pane navigation

### Mobile-First UX
- Voice input with real-time transcription and waveform visualization
- Customizable shortcut bar for frequent commands
- Zone-based haptic feedback
- File attachments: photos, camera, documents, location sharing with upload to container
- Deep link handling (`theyos://pair`, `theyos://connect`, `theyos://invite`)

## Architecture

```
TerminalApp/
  Soyeht/                  # iOS app (SwiftUI + UIKit)
    SessionStore.swift      # Auth state, server list, navigation
    SoyehtAPIClient.swift   # REST API client (instances, workspaces, claws, users)
    WebSocketTerminalView   # WebSocket terminal connection with state machine
    QRScannerView           # QR pairing camera view
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

## Terminal Engine

The embedded SwiftTerm library provides the terminal emulation core. See the [SwiftTerm documentation](https://migueldeicaza.github.io/SwiftTerm/documentation/swiftterm/) for the engine API.

Key capabilities:
- VT100/Xterm-compatible emulation with comprehensive escape sequence support
- Thread-safe Terminal instances
- Pluggable delegate model (`TerminalViewDelegate`) for custom connection backends
- Session recording and playback in asciinema `.cast` format
- Extensively tested with [esctest](https://github.com/migueldeicaza/esctest) and fuzz testing
