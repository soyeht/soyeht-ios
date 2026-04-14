**Run:** 2026-04-14 Scrollback Panel Real Device Final
**Tester:** Automated on physical device via Appium/XCUITest
**Device:** `iPhone <qa-device>` (`<ios-udid>`)
**Build Under Test:** `com.soyeht.app`
**Branch:** `split-history`

## Scope
- Floating scrollback panel sync and lifecycle after the split-history work
- Legacy `history` / `capture-pane` viewer smoke to confirm no regression
- Real-device `xcodebuild test` execution on the same physical phone

## Automated Build/Test On Real Device
- `xcodebuild test -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht -configuration Debug -destination 'id=<ios-udid>'`
- Result: `TEST SUCCEEDED`
- Suites: `22`
- Tests: `240`
- xcresult: `~/Library/Developer/Xcode/DerivedData/Soyeht-ehcrwxynhgqwaqeczmxcwwtfsyqx/Logs/Test/Test-Soyeht-2026.04.14_17-30-08--0300.xcresult`

## Real-Device QA Results

| ID | Result | Notes |
|----|--------|-------|
| ST-Q-SCRL-001 | PASS | Panel opens on the real device and immediately renders current-pane history. Evidence: `st-q-scrl-001.png` |
| ST-Q-SCRL-002 | PASS | With panel open, tapping another pane tab refreshes to that pane only. Evidence: `st-q-scrl-002.png` |
| ST-Q-SCRL-003 | PASS | Swipe on the live terminal area below the panel switches pane and refreshes panel history. Calibrated gesture lane: `y=335` on iPhone 13 mini. Evidence: `st-q-scrl-003.png` |
| ST-Q-SCRL-004 | PASS | Rapid pane changes converge to the final selected pane without mixed history. Evidence: `st-q-scrl-004.png` |
| ST-Q-SCRL-005 | PASS | After collapsing the panel, emitting fresh output, and reopening, the new marker `reopen-94b1bb` appeared in the correct pane only |
| ST-Q-SCRL-006 | PASS | Font size changed on the physical device inside `Settings > Font Size`; slider moved from `13pt` to larger values and panel row height increased on return. Font was restored to `13pt` after verification |
| ST-Q-SCRL-007 | PASS | Re-entering the terminal after session-sheet round-trip leaves exactly one scrollback panel and it still opens correctly |
| ST-Q-TMUX-009 | PASS | Legacy `history` button still opens the old viewer. In Appium XML this surfaced via the legacy viewer chrome (`pan`, `pager`, pane label `1:bash`) rather than the loading copy |

## Notes
- Long drag-heavy sessions occasionally destabilized WebDriverAgent on the device (`ECONNREFUSED 127.0.0.1:8100`). Shorter sessions with `appium:useNewWDA=true` were stable enough to complete the matrix.
- `ST-Q-SCRL-006` was validated across two short real-device sessions on the same build:
  - session 1: the font-size slider moved and the value changed on-device
  - session 2: the panel reopened on the same pane with larger row height
  - session 3: font size restored to `13pt`
- The final physical-device matrix for this branch is fully green.
