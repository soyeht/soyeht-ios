---
id: live-watch
ids: ST-Q-LIVE-001..021
profile: full
automation: assisted
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Live Watch & Diff Viewer

## Objective
Verify the Live Watch popover (real-time pane streaming via WebSocket), the git badge in the breadcrumb bar, background/foreground lifecycle, and the Peek & Pop diff viewer (long-press → peek card → full-screen diff with toolbar).

## Risk
The WebSocket stream opens on `pane-stream` using the same auth token as the PTY. If the pane_id captured from `GET /tmux/cwd` is stale or wrong, the socket connects to the wrong pane and shows unrelated output. The peek card and full-screen diff are driven by `capture-pane`, which returns raw terminal output — if the terminal emits escape sequences they must be stripped or rendered safely. The "Add to prompt" action posts a notification with the last 4,096 characters; if the commander/mirror check is missing it can inject text into a read-only mirror.

## Preconditions
- Connected to an instance terminal as **commander** (not mirror) for "Add to prompt" tests
- Active tmux session with at least one pane
- For streaming tests: a way to generate file changes (run `touch ~/Downloads/test-$(date +%s).txt` or similar)
- For "co-pilot" tests: two connected clients on the same server session

## Test Cases

### Opening and initial snapshot

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-LIVE-001 | Open file browser → tap git badge button in breadcrumb | Popover appears (380×420). Header shows current path. Status label shows `pane <id> · connecting` transitioning to `pane <id> · live` | P1 | Assisted |
| ST-Q-LIVE-002 | Popover opens | Text view populated with initial pane snapshot from `capture-pane`. Status = `live`. Spinner gone | P1 | Assisted |
| ST-Q-LIVE-003 | Open popover when pane has no context (git badge hidden) | Git badge is hidden. Popover cannot be opened. No crash | P2 | Assisted |

### Live streaming

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-LIVE-004 | With popover open, run a command in the terminal (`echo LIVE-MARKER`) | Text `LIVE-MARKER` appears in popover text view within ~2s. No full reload — content appends | P1 | Assisted |
| ST-Q-LIVE-005 | With popover open, run a command that produces many lines (e.g., `ls -la ~/Downloads/`) | All lines appear. Text view auto-scrolls to bottom | P2 | Assisted |
| ST-Q-LIVE-006 | With popover open, app goes to background for 5s, returns | Stream resumes. Fresh snapshot loaded. Status returns to `live`. Content does not duplicate | P1 | Assisted |
| ST-Q-LIVE-007 | WebSocket disconnects (toggle airplane mode briefly) | Status changes to `reconnecting 1/3`. After network returns, reconnects and resumes. Max 3 attempts shown | P1 | Assisted |

### Full-screen diff viewer

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-LIVE-008 | Tap "Open Full Screen" button in popover | `DiffViewerViewController` presented full-screen. Text view shows same content. Status label visible. Stream continues | P1 | Assisted |
| ST-Q-LIVE-009 | In full-screen: tap "↑ Top" button | Scrolls to beginning of text | P2 | Assisted |
| ST-Q-LIVE-010 | In full-screen: tap "↓ Bottom" button | Scrolls to end of text | P2 | Assisted |
| ST-Q-LIVE-011 | In full-screen: tap Copy button | Full text copied to pasteboard. Can paste in Notes to verify | P2 | Assisted |
| ST-Q-LIVE-012 | In full-screen: tap Share button | `UIActivityViewController` opens with text content | P2 | Assisted |
| ST-Q-LIVE-013 | In full-screen as **commander**: tap "Add to prompt" | Last 4,096 characters of text posted as `.soyehtInsertIntoTerminal`. Text appears in terminal prompt | P1 | Assisted |
| ST-Q-LIVE-014 | In full-screen as **mirror**: verify "Add to prompt" behavior | Button is disabled or absent. No text injected into terminal | P1 | Assisted |

### Peek & Pop (long-press diff preview)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-LIVE-015 | Long-press on the popover text view content | Peek card floats over dimmed popover background. Card shows ~20 lines of pane content with monospaced font. Hint "pressione mais → full diff" visible | P1 | Assisted |
| ST-Q-LIVE-016 | Long-press → peek card appears → release finger | Card collapses back into popover. No navigation change | P1 | Assisted |
| ST-Q-LIVE-017 | Long-press → peek card → increase pressure (or simulate 3D Touch equivalent) | Full-screen diff viewer opens (same as LIVE-008). Smooth transition | P1 | Assisted |
| ST-Q-LIVE-018 | Long-press → peek card visible → text updates arrive from stream | Peek card updates with new content. Background popover continues streaming | P2 | Assisted |

### Visual indicators (designs Lb5te, GWE10)

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-LIVE-019 | Open popover and wait for connection | Pulsing dot (double circle) appears in top-right corner of popover header — outer ring fades in/out, inner dot stays solid green | P2 | Assisted |
| ST-Q-LIVE-020 | With popover open, a new change arrives | `git_badge` in breadcrumb pulses briefly (green glow shadow, ~300ms) then returns to steady state. Badge counter increments | P2 | Assisted |
| ST-Q-LIVE-021 | With popover open, peek card appears (long-press row) | Peek card border is green (`#10B981`). When finger drags to next row, border shifts to amber (`#F59E0B`) indicating scanning state | P2 | Assisted |

## Execution Notes
- For LIVE-004 and LIVE-005, the agent can generate changes by running shell commands while the popover is open
- For LIVE-006: use the home button (or swipe up), wait 5s, return to app. The background observer stops the stream; the foreground observer restarts it
- For LIVE-007: airplane mode toggles break the WebSocket with NSError code -1005 or -1009, which are transient codes that trigger reconnect
- LIVE-013 verifies that the terminal receives the text — look for it appearing in the prompt or command buffer in the terminal view
- LIVE-015 to LIVE-018 require a device that supports force touch, or long-press with a pressure gesture in the simulator
- For LIVE-014: switch to a mirror session before opening the file browser (or test by checking the button state programmatically)

## Related Designs
- First Change (Lb5te), Streaming (GWE10), Codegen Ticker (qhpHe)
- Peek Diff (ofS1Y), Row Scanning (2GyyV), Full Diff Pop (drtnM)
