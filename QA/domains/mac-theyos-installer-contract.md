---
id: mac-theyos-installer-contract
ids: ST-Q-TINS-001..018
profile: full
automation: assisted
requires_device: false
requires_backend: false
destructive: true
cleanup_required: true
platform: macOS
---

# macOS theyOS Auto-Installer Contract

## Objective
Verify the concrete contract between the `TheyOSInstaller` Process pipeline and the theyOS CLI / backend on `feat/claw-store-macos`. This is the lowest-level slice of the Welcome onboarding: it spawns Homebrew with an explicit `/opt/homebrew/bin/brew` (falling back to `/usr/local/bin/brew` on Intel), runs `brew tap soyeht/tap && brew install theyos && soyeht start --yes`, streams phase-by-phase logs to the UI, probes `http://localhost:8892/health`, reads `~/.theyos/bootstrap-token`, and finally executes the auto-pair flow:

```
POST /api/v1/mobile/pair-token
  Authorization: Bearer <bootstrap-token>
→ { pair_token: "…" }

POST /api/v1/mobile/pair
  { pair_token, device_name, platform: "mac" }
→ { session_token, server: { host, … } }
```

The session_token is then passed into `SoyehtAPIClient.pairServer(token:host:)`, which writes it to the keychain and flips SessionStore to have an active server.

## Risk
- Brew binary not found (either Apple Silicon or Intel) → installer throws `TheyOSInstallerError.brewNotFound` but Welcome UI masks it as "install failed". Must surface the specific reason.
- `brew tap soyeht/tap` returns non-zero because tap already exists with a different URL → installer must treat this as "already tapped, proceed" rather than hard fail.
- `brew install theyos` completes but `soyeht start` was not invoked — no server running when health probe fires.
- `soyeht start` runs but binds to `0.0.0.0:8892` via Tailscale mode while UI picked localhost → health probe on `http://localhost:8892/health` succeeds coincidentally, but `bootstrap-token` is scoped to a different interface and pair-token call 401s.
- `~/.theyos/bootstrap-token` file permissions are 0o600 (only owner readable); Sandbox could block the read if the app becomes sandboxed later. For now the macOS target is NOT sandboxed — this must stay true until the installer is rewritten.
- Bootstrap token is base64-encoded or hex-encoded; `TheyOSAutoPairService` reads the raw file bytes. Any trailing newline in the file → Authorization header includes `\n` and backend returns 401 with a misleading "invalid token" message.
- Pair-token endpoint is rate-limited on backend side (e.g., 1/min). A retry loop would burn the quota and lock the user out.
- Health probe default timeout is too tight (e.g., 2s) → slow first-boot of theyOS (cold Swift package download, etc.) causes false "server didn't start" in MWEL-005.
- `soyeht start --yes` requires TTY for EULA; without a PTY it hangs forever. The installer must pipe `--yes` AND set env var `SOYEHT_NONINTERACTIVE=1` (or equivalent) — verify the actual flag the CLI accepts.
- `brew install` shows progress on stderr, not stdout; log tail view must capture BOTH streams or users see "stuck" install.

## Preconditions
- Fresh Mac (or Mac with theyOS fully removed: `brew uninstall theyos && brew untap soyeht/tap && rm -rf ~/.theyos`)
- Homebrew installed (app does NOT auto-install Homebrew itself — this is an explicit product decision)
- Port 8892 free (`lsof -i :8892` returns nothing)
- Network reachable (brew needs to fetch the tap and formula)

## How to automate
- **Drive installer**: launch app via `mcp__XcodeBuildMCP__build_run_sim` macOS target, follow the Welcome flow.
- **Capture logs**: `TheyOSInstaller` writes each stdout/stderr line to its `logLines` published property — UI shows them and test can tail them via accessibility tree (`soyeht.welcome.install.logTail`).
- **Verify process tree**: `pgrep -f soyeht-server` after install completes; must return a PID.
- **Inspect bootstrap-token**: `stat -f '%Lp' ~/.theyos/bootstrap-token` → expect `600`. `wc -c ~/.theyos/bootstrap-token` must match the length reported to `pair-token` endpoint in the captured HTTP request.
- **Capture HTTP**: run `mitmproxy -p 8891 --mode reverse:http://localhost:8892` and repoint installer's adminHost to `http://localhost:8891` via a debug build setting. Inspect the `/api/v1/mobile/pair-token` request body and response.

## Test Cases

### Homebrew resolution

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TINS-001 | On Apple Silicon, brew at `/opt/homebrew/bin/brew` | Installer picks this path. Install proceeds | P0 | Yes |
| ST-Q-TINS-002 | On Intel mac, brew at `/usr/local/bin/brew` | Installer picks this path. Install proceeds | P1 | Assisted |
| ST-Q-TINS-003 | Brew NOT installed on either path | Installer surfaces `TheyOSInstallerError.brewNotFound` with user-facing text: "Homebrew is required. Install from brew.sh." Link button opens brew.sh in browser | P0 | Assisted |

### Tap / install happy path

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TINS-004 | `brew tap soyeht/tap` when tap is absent | Succeeds. UI phase advances to "Installing theyos…". Log tail shows tap URL | P0 | Yes |
| ST-Q-TINS-005 | `brew tap soyeht/tap` when already tapped | Non-fatal. Install proceeds without re-tapping | P1 | Yes |
| ST-Q-TINS-006 | `brew install theyos` succeeds | Log tail shows brew download + linking. Phase advances to "Starting theyos…" | P0 | Yes |
| ST-Q-TINS-007 | `soyeht start --yes` (localhost mode) | Process stays alive (background). stdout shows `listening on :8892`. Phase advances to "Checking server…" | P0 | Yes |

### Health probe timing

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TINS-008 | Health prober polls `GET http://localhost:8892/health` every 500ms | Gives up only after ≥20s (not 2s). Success on first 200 response | P0 | Yes |
| ST-Q-TINS-009 | theyOS boot takes 10s on first cold launch | Probe still succeeds. UI shows "Checking server (5s)…" style countdown or indeterminate spinner | P1 | Yes |
| ST-Q-TINS-010 | Port 8892 is ALREADY bound by unrelated process | Probe succeeds but auto-pair fails with HTTP 401/404 → surface error "another service is using port 8892. Stop it and try again." (not a cryptic network error) | P1 | Assisted |

### Bootstrap token read

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TINS-011 | `~/.theyos/bootstrap-token` exists, mode 0600, no trailing newline | Reader returns exact bytes. Authorization header = `Bearer <trimmed>`. No injected whitespace | P0 | Yes |
| ST-Q-TINS-012 | Token file has trailing `\n` | Reader strips it. Header still valid | P1 | Yes |
| ST-Q-TINS-013 | Token file missing (install incomplete) | Installer surfaces a distinct error phase `bootstrapTokenMissing` — not "pairing failed" | P1 | Assisted |

### Pair token + session token

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TINS-014 | `POST /api/v1/mobile/pair-token` with valid bootstrap | Returns 200 with `{ pair_token: "..." }`. Installer passes to `pairServer` | P0 | Yes |
| ST-Q-TINS-015 | Pair-token endpoint returns 429 (rate limit) | Installer does NOT retry in a tight loop. Surfaces "try again in N seconds" to user | P1 | Assisted |
| ST-Q-TINS-016 | `POST /api/v1/mobile/pair` with valid pair_token | Returns 200 with `{ session_token, server }`. `SoyehtAPIClient.pairServer` writes token to keychain; SessionStore gains a paired server; Welcome dismisses | P0 | Yes |
| ST-Q-TINS-017 | Pair endpoint returns 401 (bootstrap expired / pair_token stale) | Welcome surfaces a user-facing message and offers "Retry" (which re-fetches bootstrap-token and pair-token) without needing a full reinstall | P1 | Assisted |

### Cleanup on install failure

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TINS-018 | User cancels install mid-`brew install theyos` (Cmd+. or Welcome window close) | The `brew install` subprocess is terminated cleanly (SIGINT, not SIGKILL). No orphan `brew` or `soyeht-server` processes. `~/.theyos/` left partially populated is acceptable but a retry from Welcome completes the install cleanly | P1 | Manual |

## Related code
- `TerminalApp/SoyehtMac/Welcome/TheyOSInstaller.swift` — Process pipeline, phase enum, log line streaming
- `TerminalApp/SoyehtMac/Welcome/TheyOSEnvironment.swift` — brew binary candidates, bootstrap-token path, adminHost, Tailscale detection
- `TerminalApp/SoyehtMac/Welcome/TheyOSHealthProber.swift` — actor, polls `/health`
- `TerminalApp/SoyehtMac/Welcome/TheyOSAutoPairService.swift` — reads bootstrap-token, POSTs to `/mobile/pair-token` + `/mobile/pair`, calls `pairServer`
- `Packages/SoyehtCore/.../API/SoyehtAPIClient.swift` — `pairServer(token:host:)`

## Cleanup
- If install happens on a dev machine and should NOT persist: `brew uninstall theyos && brew untap soyeht/tap && rm -rf ~/.theyos`
- If Tailscale mode was used for MWEL-009: `soyeht stop` and reconfigure if a different mode was the pre-test state
- Kill orphan `soyeht-server` processes: `pkill -f soyeht-server`
