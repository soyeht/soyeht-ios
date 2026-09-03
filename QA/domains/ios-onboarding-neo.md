---
id: ios-onboarding-neo
ids: ST-Q-IOSN-001..014
profile: standard
automation: assisted
requires_device: true
requires_backend: mac
destructive: true
cleanup_required: true
platform: iOS
---

# iPhone onboarding — six screens, then a terminal

Never a simulator for these. The radar needs Bonjour and a tailnet, the Face
ID switch needs a Secure Enclave, and the whole point is what a person sees
holding the phone.

| # | Screen | What it must do |
|---|---|---|
| I1 | "Your Mac, in your pocket." | One paragraph, one button. This is the whole introduction; the six-card carousel is gone. |
| I2 | "Is Soyeht already on your Mac?" | Three answers. "Yes" and "Not yet" both end on the radar — "Not yet" shares the macOS link first. Only Linux leaves the Mac path. |
| I3 | Radar | A status line per phase, never one spinner for six situations. One line about Tailscale. |
| I4 | "Is this your Mac?" | The Mac's name, the house name, six words in 2×3 wells, and **two** answers: connect, or "Not my Mac". |
| I5 | "<Mac> is yours." | Shown to everyone who pairs — radar, QR, or link. Carries the Face ID switch. The CTA is never gated on it. |
| I6 | Home | The house, its Mac with a live status, the sessions running on it, "New session", and "Other machines". |
| I8 | "I can't find your Mac yet." | Reached from I3 when the search stalls. Causes are derived from the phase, never a fixed list. |

## What the checks are

- **ST-Q-IOSN-001 — zero to a terminal.** Reset both devices (T070), walk
  I1 → I2 → I3 → I4 → I5 → home, tap New session. A shell opens on the Mac
  and the phone lands in it.
- **ST-Q-IOSN-002 — the words match.** The six on I4 equal the six on M4,
  character for character, and they follow the Mac when it rotates its window.
- **ST-Q-IOSN-003 — "Not my Mac" works.** Reject the candidate: the card goes,
  the radar restarts, and the same household does not come straight back on
  the next push. Relaunching the app offers it again — the rejection is
  session-scoped and never written to disk.
- **ST-Q-IOSN-004 — the phone waits honestly while the Mac is set up.** Open
  the phone first. I3 says the Mac was found and is finishing setup, with no
  deadline, and reaches I4 within about five seconds of the Mac naming its
  home.
- **ST-Q-IOSN-005 — a Mac that already has a home is not called unreachable.**
  Point a paired phone-less iPhone at a `ready` Mac: the radar stops and the
  screen says to add this iPhone from the Mac, rather than "Mac unreachable".
- **ST-Q-IOSN-006 — I8 gives reasons, not a shrug.** Close Soyeht on the Mac.
  Within about twenty seconds I3 becomes I8 with causes that match what was
  actually observed, plus Keep looking and Get the link.
- **ST-Q-IOSN-007 — Get the link keeps looking.** Tapping it opens the share
  sheet over a still-running radar; a Mac that comes up mid-share is found.
- **ST-Q-IOSN-008 — the celebration is reached by every path.** Radar, QR and
  link all land on I5. The first owner — the person who set the Mac up — sees
  it too.
- **ST-Q-IOSN-009 — Face ID never blocks the way out.** Cancel the ceremony:
  the switch returns to off, the copy says it can be turned on later in
  Settings, and "Open a terminal" still works.
- **ST-Q-IOSN-010 — no splash after the celebration.** "Open a terminal" lands
  in the home in well under a second; the two-second splash is for cold
  launches.
- **ST-Q-IOSN-011 — the home names the Mac.** The row reads the canonical
  `displayName`, never a raw identifier, and its status follows the presence
  socket: kill Soyeht on the Mac and it says offline.
- **ST-Q-IOSN-012 — New session opens a pane on the Mac.** The phone sends
  `open_pane`; the Mac creates a real shell and answers with its id. The
  phone attaches to that id, never one it invented.
- **ST-Q-IOSN-013 — a second tap is refused, not queued.** Tapping New session
  twice quickly opens one pane.
- **ST-Q-IOSN-014 — Other machines still reaches everything.** Linux servers,
  base machines and apps are one tap below the home, and every route out of
  that list dismisses it.

## Automation

WDA on the physical device, through `iproxy 8210:8100` — never 8101, which is
the Dev engine's household port. Find by `soyeht.onboarding.*` and
`soyeht.home.*`. Screenshots to `QA/runs/<date>/screenshots/`, gitignored.

Never print the UDID. Never pair the Dev phone against the production engine:
both Macs push claims at a fresh phone on this machine, and the claim that
lands last is the one the card shows.
