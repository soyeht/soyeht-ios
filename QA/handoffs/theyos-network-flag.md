# Handoff — `soyeht start --network` flag (theyos repo)

**Status:** Swift side landed; Rust side pending separate chat in `~/Documents/theyos`.

## Why

PR #9 (Claw Store + Welcome onboarding for macOS) added a network-mode
picker to the Welcome flow ("Só eu neste Mac" vs "Eu + outros
dispositivos via Tailscale"). The Swift installer (`TheyOSInstaller`)
needs to tell `soyeht start` which bind to use. Today the CLI has no
flag for it and always lets `server-rs` default to `0.0.0.0:8090` via
the `ADDR` env var.

The Swift side is **already tolerant of the CLI not having the flag** —
it probes `soyeht start --help`, greps for `--network`, and only passes
the flag if it sees it. So shipping the app before the Rust flag lands
is safe; the app just falls back to the default bind with a warning in
the install log.

## Changes required in `~/Documents/theyos` (crate `soyeht-rs`)

### 1. `admin/rust/soyeht-rs/src/cli.rs`

Add a `NetworkMode` value enum and a `network` arg on `StartArgs`:

```rust
use clap::{Parser, Subcommand, ValueEnum};

#[derive(Copy, Clone, Debug, ValueEnum, PartialEq, Eq)]
pub enum NetworkMode {
    Localhost,
    Tailscale,
}

impl NetworkMode {
    pub fn addr_env_value(self) -> &'static str {
        match self {
            NetworkMode::Localhost => "127.0.0.1:8090",
            NetworkMode::Tailscale => "0.0.0.0:8090",
        }
    }
}

#[derive(clap::Args)]
pub struct StartArgs {
    #[arg(long)]
    pub clean: bool,
    #[arg(long, short = 'y')]
    pub yes: bool,
    #[arg(long)]
    pub skip_init: bool,
    /// Bind interface. `localhost` keeps the admin backend on 127.0.0.1
    /// only; `tailscale` exposes 0.0.0.0 so other devices on the
    /// tailnet reach it.
    #[arg(long, value_enum, default_value_t = NetworkMode::Localhost)]
    pub network: NetworkMode,
}
```

### 2. `admin/rust/soyeht-rs/src/main.rs`

Plumb the flag through `cmd_start`:

```rust
Commands::Start(a) => {
    infra::cmd_start(&root, a.clean, a.yes, a.skip_init, a.network);
}
```

### 3. `admin/rust/soyeht-rs/src/infra.rs`

Accept the new arg and set the env var before spawning:

```rust
pub fn cmd_start(
    root: &Path,
    _clean: bool,
    skip_confirm: bool,
    skip_init: bool,
    network: crate::cli::NetworkMode,
) {
    // ... existing NixOS / macOS init logic ...

    // Bind the admin backend based on the picked network mode. Child
    // processes inherit the env, so setting it here is enough.
    std::env::set_var("ADDR", network.addr_env_value());

    if !start_admin_backend(root) {
        std::process::exit(1);
    }
    println!("[soyeht] services started (bind={})", network.addr_env_value());
}
```

### 4. Tests

Unit tests around `NetworkMode::addr_env_value()`:

```rust
#[test]
fn network_mode_addr_localhost() {
    assert_eq!(NetworkMode::Localhost.addr_env_value(), "127.0.0.1:8090");
}

#[test]
fn network_mode_addr_tailscale() {
    assert_eq!(NetworkMode::Tailscale.addr_env_value(), "0.0.0.0:8090");
}
```

### 5. Release

Once landed + tapped in Homebrew, the Swift probe
(`TheyOSEnvironment.cliSupportsNetworkFlag`) will start seeing
`--network` in `--help` and the installer will pass it automatically.
No app-side change required on release.

## Verification once merged

1. `brew upgrade theyos`
2. `soyeht start --help` shows `--network`.
3. `soyeht start --network=localhost` starts admin bound to 127.0.0.1.
   Confirm with `curl http://127.0.0.1:8090/health` (works) and
   `curl http://$(hostname -I | awk '{print $1}'):8090/health` (fails).
4. `soyeht stop; soyeht start --network=tailscale` starts on 0.0.0.0
   and is reachable from a second tailnet device.

## References

- Swift side PR #9, branch `feat/claw-store-macos`.
- Swift probe: `TerminalApp/SoyehtMac/Welcome/TheyOSEnvironment.swift`
  — `cliSupportsNetworkFlag(binary:)`.
- Swift arg builder:
  `TerminalApp/SoyehtMac/Welcome/TheyOSInstaller.swift` —
  `buildStartArgs(mode:supportsNetworkFlag:)`.
- QA contract: `QA/domains/mac-theyos-installer-contract.md` TINS-007.
- QA contract: `QA/domains/mac-welcome-onboarding.md` MWEL-009.
