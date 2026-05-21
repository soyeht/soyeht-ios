# Post-merge recovery — Bug 1 (ATS -1022) + Bug 2 (Mac.app listener bypass)

Branch: `fix/post-merge-recovery` (off `origin/main` @ `2ccdbe5`).
Canonical plan source: `~/.claude/plans/voc-vai-resolver-dois-functional-lantern.md`.
Date: 2026-05-21.

## Why this exists

PR #109 (`2ccdbe5`) landed a 10-commit Caso-B remediation and was validated
on Flow 10 (Linux→iPhone). When the 8-flow matrix was re-walked on
hardware after the merge, two operational defects surfaced that the PR
did not cover.

## Bug 1 — iPhone Soyeht.app: `URLError.-1022` while polling Mac engine

Symptom: `AwaitingMacView` reports
`"Mac unreachable (retry N) — URLError.-1022 The resource could not be
loaded because the App Transport Security policy requires the use of a
secure connection."` against `http://100.103.149.48:8091/bootstrap/status`,
even though:

- The installed bundle Info.plist contains both `NSAllowsArbitraryLoads=1`
  and `NSAllowsLocalNetworking=1`
  (`TerminalApp/Soyeht/Info.plist:102–129`).
- Safari on the same iPhone hits the URL fine.
- The HTTP client uses `URLSession.shared.data(for: req)` with no custom
  delegate / TLS override
  (`Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapStatusClient.swift:37`).
- The theyos engine publishes `mac_engine_url =
  http://<tailnet-ipv4>:<port>` correctly
  (`theyos@4abb72a admin/rust/server-rs/src/tailnet_address.rs::build_mac_engine_url`).

Approach: instrument first, then patch (per Caio's choice 2026-05-21).

### Step 1 — Instrumentation (commit A)

Add structured os_log + on-screen URL details. Three sites:

- `TerminalApp/Soyeht/Onboarding/Proximity/AwaitingMacView.swift:363`
  (inside `publisher.onMacClaimed`) — log `claim.received url=…
  scheme=… host=… port=…`.
- Same file, inside `probeRawError(for:)` ≈ line 559 — log
  `probe.url string=… scheme=… host=… port=…`; extend
  `diagnosticMessage` to surface `host:port` on screen.
- `Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/SetupInvitationPublisher.swift:425`
  inside `SetupInvitationDirectClaim.decode(_:)` — log
  `decode.mac_engine_url raw=… parsed=…`.

### Step 2 — Capture (no commit yet)

`xcodebuild` + `xcrun devicectl device install app`, then capture iPhone
logs with `idevicesyslog -u 00008110-001A48190231801E` (devicectl 518.31
has no `device logs` subcommand). Walk iPhone Welcome → My Mac → Yes I am
at Mac while Mac.app shows ExistingSoyehtView.

### Step 3 — Patch (commit B)

Decision matrix from the canonical plan (single closed action per row).
Strong-favored outcome (~85% per Apple's `NSAllowsArbitraryLoads` ref doc
which states `NSAllowsArbitraryLoads` is ignored when
`NSAllowsLocalNetworking` is present): **strip `NSAllowsLocalNetworking`
from `TerminalApp/Soyeht/Info.plist:102–129` and rewrite the misleading
`<!-- ... -->` comment block** (current comment claims the two flags
are "belt-and-suspenders" — Apple's docs say the opposite).

If logs show a different root cause (https:// upgrade, malformed host,
dropped port, claim never arrives), follow the corresponding matrix
branch — none of those involve Info.plist.

## Bug 2 — Mac.app "Continue with this Mac" kills SetupInvitationListener

Symptom: when the Mac engine is `.uninitialized` / `.readyForNaming`,
Mac.app shows ExistingSoyehtView; clicking "Continue with this Mac"
forces solo-founder (HouseNamingView) and the
`SetupInvitationListener` loop in
`TerminalApp/SoyehtMac/Welcome/WelcomeRootView.swift:146` dies because
`continueWithExistingSoyeht` sets `keepListening = false` (line 203). An
iPhone publishing setup-invitation at that moment is missed silently.

### Fix (commit C — coordinated changes in `WelcomeRootView.swift`)

- **2.1** — `continueWithExistingSoyeht` (line 202) no longer flips
  `keepListening` for `.uninitialized` / `.readyForNaming`; keeps the
  listener loop alive while user navigates to HouseNamingView.
- **2.2** — `bootstrapStep(.houseNaming)` (line 108) flips
  `keepListening = false` inside `HouseNamingView.onNamed` — the actual
  commit moment to solo-founder.
- **2.3** — `resolveMode()` `.notFound`/`.failed` branch (line 175)
  respects in-progress bootstrap navigation: if `mode == .bootstrap` and
  `!bootstrapPath.isEmpty`, do not yank back to ExistingSoyeht. Listener
  keeps running silently; only an `invitationClaimed` event swaps mode
  to `.setupAwaiting`.
- **2.4** — refresh the now-stale comments at lines 63–74
  (`BootstrapWelcomeView.onContinue`), lines 143–145 (`resolveMode`
  docstring), and add a comment near the new `.bootstrap +
  !bootstrapPath.isEmpty` arm. Phrasing must be generic enough to cover
  any future in-progress bootstrap navigation, not just
  Continue→HouseNaming.

## Bug 3 — theyos — N/A unless Step 3 routes there

Engine code is correct (`tailnet_address.rs::build_mac_engine_url`
formats `http://{ipv4}:{port}`). theyos worktree at
`/Users/macstudio/Documents/theyos-recovery-fix` is created defensively
and removed pre-commit if not used.

## Build hygiene + validation

- `killall xcodebuild` then `rm -rf /tmp/soyeht-build
  /tmp/soyeht-mac-build` before any build (memory
  `feedback_fresh_install_is_the_only_truth`).
- iPhone build with `-derivedDataPath /tmp/soyeht-build`.
- Mac.app build with `-derivedDataPath /tmp/soyeht-mac-build`.
- 8 reachable flows from `docs/household-12-flow-matrix.md` walked on
  Mac Studio + iPhone Devs (UDID
  `134D4422-B6D0-518B-8D4C-8B608C0F00CD`) + Linux NUC7i7BNH via
  `ssh devs`.
- Per-flow reset uses file-level cleanup, not `POST /bootstrap/teardown`
  (the endpoint exists but is CBOR-bodied and refuses unauth when state
  ≥ `named_awaiting_pair`). See
  `TerminalApp/SoyehtMac/Welcome/WelcomeRootView.swift:638`
  (`ExistingSoyehtStateResetter`) for the canonical file list.
- Aggregate evidence into `docs/8-flow-validation-2026-05-21.md`
  (`/bootstrap/status` JSON + iPhone HouseholdHomeView screenshots).

## PRs

Separate PR per repo; auto-merge disabled
(memory `feedback_review_then_automerge`). English-only artifacts
(memory `feedback_code_artifacts_in_english`).
