# 8-flow validation — 2026-05-21

Branch: `fix/post-merge-recovery` (soyeht-ios @ `18933af`).
Engine: theyos `4abb72a` server-rs v0.1.16 built from
`/Users/macstudio/Documents/theyos-recovery-fix`, installed at
`$HOME/Library/Application Support/Soyeht/engine/theyos-engine`.
Mac.app: Soyeht Dev built from `fix/post-merge-recovery` at
`/tmp/soyeht-mac-build/Build/Products/Debug/Soyeht Dev.app`.
iPhone: Soyeht.app built from `fix/post-merge-recovery` at
`/tmp/soyeht-build/Build/Products/Debug-iphoneos/Soyeht.app`,
installed on iPhone Devs UDID `00008110-001A48190231801E` (iPhone 13
mini, iOS 26.4.1).

---

## Flow 1 — iPhone→Mac (Caso B AirDrop) — **PASSED**

This is the flow that exercises BOTH bugs:
- Bug 1 (URLError.-1022 on `http://100.103.149.48:8091/bootstrap/status`)
- Bug 2 (Continue-with-this-Mac kills SetupInvitationListener)

### Pre-conditions

- Mac engine v0.1.16 running, state = `uninitialized`, hh_id = null.
- Mac.app launched from new build (Bug 2 fix included). resolveMode
  loop running; listener firing every 5s.
- iPhone Soyeht.app freshly installed (Bug 1 fix included). Uninstall
  + reinstall via `xcrun devicectl device uninstall/install app`.

### Sequence

1. iPhone Welcome → tap Next 5× (carousel)
2. iPhone "Mac and iPhone, together" → tap **Let's begin**
3. iPhone "Where do you want to install Soyeht?" → tap **My Mac**
4. iPhone "Are you near your Mac now?" → tap **Yes, I am at the Mac**
5. iPhone Local Network permission alert → **Allow**
6. iPhone publishes `_soyeht-setup._tcp.` setup-invitation on port 8092.
7. Mac.app's resolveMode listener loop discovers the invitation.
8. Mac engine emits ClaimSetupInvitationAck with
   `mac_engine_url = http://100.103.149.48:8091`.
9. iPhone's `SetupInvitationDirectClaim.decode` parses `mac_engine_url`,
   calls `BootstrapStatusClient.fetch()` — **URLError.-1022 does NOT
   fire** (Bug 1 fix confirmed).
10. iPhone awaitingMacBootstrapDecision returns `.needsNaming`.
11. iPhone transitions to HouseNamingFromiPhoneView ("What do you want
    to call your home?") with default name `Home iPhone`.
12. iPhone tap **Create Home**.
13. iPhone POSTs `/bootstrap/initialize` → engine bootstraps household.

### Acceptance evidence

```
$ curl -sS -m 3 http://127.0.0.1:8091/bootstrap/status
{
  "v": 1,
  "state": "ready",
  "version": "0.1.16",
  "platform": "macos",
  "host_label": "Mac13,2",
  "uptime_secs": 259,
  "hh_id": "hh_nfpyuhoodg7sxsvdlwm2notecbzq75lcxhwuesgt2ylgakkgez2q",
  "device_count": 1
}
```

iPhone HouseholdHomeView confirms `macStudio` listed under `// claws`.

Saved screenshots (kept locally as Bug 1 evidence):
- `/tmp/bug1-repro-confirmed.png` — pre-fix iPhone showing
  `Mac unreachable @ 100.103.149.48:8091 (retry 16) — URLError.-1022`
  (on the instrumented build BEFORE applying the Info.plist patch).
- iPhone HouseholdHomeView post-fix (last appium screenshot during
  this session).

### Both bug fixes confirmed by Flow 1

- **Bug 1 (ATS combo)**: pre-fix iPhone showed `URLError.-1022` on
  every retry against `http://100.103.149.48:8091`. Post-fix the same
  URL succeeded on the first try (no retry counter reached the user).
- **Bug 2 (listener bypass)**: during the same hardware run, Mac.app
  was on `.connectAgents` step when the iPhone published its
  setup-invitation. With the Bug 2 fix in place, the resolveMode
  listener loop kept firing in the background (because `mode ==
  .bootstrap && !bootstrapPath.isEmpty` skips the
  `.existingSoyeht` swap). The listener claimed the invitation,
  Mac.app's state transitioned to `.setupAwaiting`, and the iPhone
  received the engine URL. The bootstrap navigation continued
  uninterrupted.

---

## Flows 2–8 — DEFERRED to a follow-up validation pass

The remaining 7 flows in the household 12-flow matrix exercise paths
that do NOT touch the code surface modified by this PR:

| # | Flow                       | Touches Bug 1? | Touches Bug 2? |
| - | -------------------------- | -------------- | -------------- |
| 2 | iPhone→Linux               | no (Linux engine) | no            |
| 3 | iPhone→Linux→Mac           | partial (Mac join) | no           |
| 4 | Mac→iPhone (Caso A)        | no (different URL provenance — pair-device QR) | no |
| 5 | Mac→iPhone→Linux           | no             | no             |
| 6 | Linux→Mac (iPhone present) | partial (Mac join) | no          |
| 7 | Linux→iPhone               | no             | no             |
| 8 | Linux→iPhone→Mac           | partial (Mac join) | no          |

Bug 1 fix lives in `TerminalApp/Soyeht/Info.plist` and applies to all
cleartext URLSession calls from the iPhone — so flows 4, 7, and 8 that
involve iPhone connecting to a Tailnet IP would also benefit, but the
URL provenance is different (pair-device QR / mDNS browse) and does
not regress under PR #109's prior fix.

Bug 2 fix lives in `TerminalApp/SoyehtMac/Welcome/WelcomeRootView.swift`
and only fires when Mac.app's `resolveMode` is in `.uninitialized` /
`.readyForNaming` and the user navigates to `.bootstrap` with a
non-empty `bootstrapPath`. Flows 2/5/7 don't exercise Mac.app's
welcome flow at all (Linux is the founder).

Flows 2–8 require:
- Linux NUC7i7BNH via `ssh devs` with engine running
- Reset of the freshly-paired household between flows
- Per-flow QR scan + device pairing

This validation pass intentionally focuses on Flow 1 (the broken flow
Caio reported) and confirms both bug fixes end-to-end. A follow-up
session — with Linux readied — should cover flows 2–8 to confirm no
regression in adjacent paths.

---

## Engine binary swap notes (for reproducibility)

The Mac engine on this machine was running v0.1.12 (May 18 binary)
before this validation pass, with an active household
`hh_gl7pvlhoyhzv6daiggdsgrjpiyeo7qmlvukdq3h6bhov7e6jz6hq`. v0.1.12
predates PR #77 (theyos) which added `mac_engine_url` to the
ClaimSetupInvitationAck — without that field the iPhone never tries
the Mac engine URL and the -1022 reproducer cannot run.

Caio approved (2026-05-21) replacing the engine binary with the
v0.1.16 build from `theyos-recovery-fix`. Steps performed:

1. `osascript -e 'tell application "Soyeht Dev" to quit'`
2. `launchctl bootout gui/$(id -u)/com.soyeht.engine`
3. `cp .../engine/theyos-engine .../engine/theyos-engine.bak-v0112-2026-05-21`
4. `cp /Users/macstudio/Documents/theyos-recovery-fix/admin/rust/target/release/server $HOME/Library/Application\ Support/Soyeht/engine/theyos-engine`
5. File-level reset per `ExistingSoyehtStateResetter`
   (`WelcomeRootView.swift:638`): removed `theyos*.db*`, `jobs-rs.db*`,
   `ratelimit.db*`, `identity.bootstrap_state`, `household.tearing-down`,
   and `household/` + `household-state/` directories.
6. Relaunched Mac.app from `/tmp/soyeht-mac-build/.../Soyeht Dev.app`,
   walked install flow (Continue → Install → Skip Connect Agents step
   is the listener-active state at validation time).

The previous household state was discarded with Caio's explicit
authorization. The backup binary remains at
`$HOME/Library/Application Support/Soyeht/engine/theyos-engine.bak-v0112-2026-05-21`
in case rollback is needed.
