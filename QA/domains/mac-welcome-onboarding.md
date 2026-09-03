---
id: mac-welcome-onboarding
ids: ST-Q-MWEL-101..112
profile: standard
automation: assisted
requires_device: false
requires_backend: mac
destructive: true
cleanup_required: true
platform: macOS
---

# macOS Welcome — four screens, then a terminal

The Mac names the home. It always did in the engine's model; the app used to
disagree with it, hand naming to the phone on a claim, and ask the engine to
initialize with a claim token nothing modelled. That is gone.

Four screens, all at 720×540 on the neo canvas, with the progress dots saying
which of the four you are on:

| # | Screen | What it must do |
|---|---|---|
| M1 | "Welcome to Soyeht." | One paragraph, one button. No telemetry checkbox — that lives in Settings › General, default off. |
| M2 | "Setting up…" | One progress bar with three phases. The Login Items card appears **inline**, never replacing the body, and re-checks itself when the app comes back from System Settings. |
| M3 | "Name your home." | One field, one button. The busy state is `HouseCreationProgressView`, not a fourth screen. |
| M4 | "Add your iPhone." | Six words in 2×3 wells, a QR from the same link, "Waiting for your iPhone…", and one line about Tailscale. Skip is a real exit. |
| M6 | "<Mac> is ready." | Reached automatically when the engine is `.ready` **and** `device_count >= 1`, or from Skip. "Connect agents" pushes M5; "Open Soyeht" opens the main window with a live shell. |

M5 (Connect agents) is optional and reached only from M6.

## What the checks are

- **ST-Q-MWEL-101 — a Mac from zero reaches a live shell.** Reset with the
  T070 runbook, walk M1 → M6, click Open Soyeht. The window opens on a shell
  with a prompt: no picker, no "Could not open the local shell" alert. The
  Console shows exactly one `attached(reconnected: false)`.
- **ST-Q-MWEL-102 — quit and relaunch stays in.** After M6, quit and reopen.
  The main window comes back; the Welcome does not.
- **ST-Q-MWEL-103 — the six words match.** Read `soyeht.welcome.m4.word.1…6`
  off the Mac and compare with the phone's I4. They are equal, always, and
  they rotate together: wait six minutes and pair with the new QR.
- **ST-Q-MWEL-104 — M4 advances by itself.** With the phone confirming, the
  Mac reaches M6 with no click.
- **ST-Q-MWEL-105 — Skip mints the credential.** Skip from M4, then relaunch:
  the main window opens, not the Welcome.
- **ST-Q-MWEL-106 — the Login Items card is inline and self-clearing.** Deny
  approval once. The card appears inside M2 with the body still visible;
  approve in System Settings and come back — it continues without a click.
- **ST-Q-MWEL-107 — the window is neo.** 720×540, `NeoPalette.cloud`, light
  appearance regardless of `DesignStyle.active`. A `defaults write
  com.soyeht.mac.dev soyeht.design.style classic` leaves the *main* window
  classic and the Welcome unchanged.
- **ST-Q-MWEL-108 — a fresh install wakes up in Neo Milk.** First launch on a
  reset Mac: main window in Neo Milk, `.neomorphic` style. An existing user
  who chose classic is never converted.
- **ST-Q-MWEL-109 — "Soyeht is already installed" is one screen.** An engine
  answering `uninitialized` outside bootstrap shows `ExistingSoyehtView`, not
  a join-or-start fork. Joining lives in Settings › Devices.
- **ST-Q-MWEL-110 — a failed reinstall keeps watching.** Make the stop fail;
  the screen shows its error *and* keeps polling, so a recovered engine is
  noticed without pressing Try again.
- **ST-Q-MWEL-111 — Settings › Devices offers the three.** "Join an existing
  Soyeht…", "Add a Linux server…", "Forget this home…" are all visible in the
  pane without scrolling.
- **ST-Q-MWEL-112 — Forget this home does what it says.** Confirm the alert:
  the Dev engine stops answering, the main windows close, the Welcome reopens
  at M1, and the production engine on its own port is untouched.

## What is gone, and why

The Homebrew era (ST-Q-MWEL-001..021) is retired with the screens it tested:
the install picker, the network-mode picker, the clipboard auto-paste, the
carousel, the join-or-start fork, the auto-join screen, the house avatar and
its celebration card, the standalone safety-code display. `soyeht start
--help` probing and `QA/handoffs/theyos-network-flag.md` went with them — the
engine ships inside the app now and `EnginePackager.install()` is the only
installer.

"Start over…" is "Forget this home…", and it no longer opens the uninstaller.
The uninstaller is still there, under Soyeht › Uninstall Soyeht, for removing
the app itself.

## Automation

`native-devtools`: `focus_window "Soyeht Dev"` → `find_text` by button title →
`click`. Accessibility ids are `soyeht.welcome.*` for the flow and
`prefs.devices.*` for the pane. Screenshots go to `QA/runs/<date>/screenshots/`
— gitignored, because a device screenshot carries the machine name and its
tailnet address in plain text and this repository is public.
