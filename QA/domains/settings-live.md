---
id: settings-live
ids: ST-Q-SETS-001..007
profile: full
automation: assisted
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Settings Live Updates

## Objective
Verify that font size, cursor style, cursor color, theme, and shortcut bar changes apply immediately to an open terminal and persist after relaunch.

## Risk
All settings use `.soyehtXxxChanged` notifications. If observer is removed during viewDidDisappear but terminal is still on-screen (e.g., sheet presentation), notification is lost and setting doesn't apply.

## Preconditions
- Connected to an instance with open terminal

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-SETS-001 | Change font size (e.g., 12 to 16) | Terminal text changes size immediately | P2 | Assisted |
| ST-Q-SETS-002 | Change cursor style (block to beam) | Cursor shape changes immediately | P2 | Assisted |
| ST-Q-SETS-003 | Change cursor color | Cursor color changes immediately | P3 | Assisted |
| ST-Q-SETS-004 | Change color theme | Terminal background and text colors change immediately | P2 | Assisted |
| ST-Q-SETS-005 | Change shortcut bar config | Shortcut bar above keyboard updates immediately | P2 | Assisted |
| ST-Q-SETS-006 | Kill and relaunch after all changes | Settings persist. Terminal opens with new font, cursor, theme, shortcuts | P1 | Yes |
| ST-Q-SETS-007 | Rapidly toggle theme 5 times | No crash. Final theme applied correctly. No glitches | P2 | Yes |
