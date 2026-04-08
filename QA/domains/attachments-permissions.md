---
id: attachments-permissions
ids: ST-Q-ATCH-001..014
profile: full
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Attachments & Permissions

## Objective
Verify attachment types that Appium can drive (documents, files, location), menu display, cancellation, permission denial, and server-side receipt verification.

## Risk
PHPicker results have temp URLs that invalidate on picker completion. If app doesn't copy files immediately, uploads fail silently.

## Preconditions
- Connected to an instance terminal
- Location services available

## IMPORTANT: Photos and Camera are excluded from automated testing
Appium cannot reliably interact with the iOS photo picker or camera UI. Photos and Camera tests are manual-only and should be done by the human tester separately. The automated suite focuses on Documents, Files, and Location.

## How to verify upload on server
After uploading a file, the agent MUST verify it arrived on the server:
1. In the terminal, run `ls ~/Downloads/` (or the upload target directory)
2. Verify the uploaded filename appears
3. This confirms the full round-trip: picker → app → WebSocket → server → filesystem

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-ATCH-001 | Open attachment menu in terminal | Shows all 5 options: Photos, Camera, Location, Document, Files | P1 | Yes |
| ST-Q-ATCH-002 | Select Document, pick a PDF | PDF uploaded. Filename preserved. Verify with `ls ~/Downloads/` in terminal | P1 | Yes |
| ST-Q-ATCH-003 | Select Files, pick any file | File uploaded. Filename and extension preserved. Verify with `ls ~/Downloads/` | P1 | Yes |
| ST-Q-ATCH-004 | Select Location, allow permission | GPS coordinates sent to terminal | P1 | Yes |
| ST-Q-ATCH-005 | Select Location with permission denied (Settings > Soyeht > Never) | Permission denied message. Offers to open Settings. No crash | P1 | Assisted |
| ST-Q-ATCH-006 | Select Document, cancel without selecting | Picker dismissed. No error. Terminal functional | P2 | Yes |
| ST-Q-ATCH-007 | Select Files, cancel without selecting | Picker dismissed. No error. Terminal functional | P2 | Yes |
| ST-Q-ATCH-008 | Upload large file (10MB+) via Files | Completes with progress indicator. No timeout. Verify with `ls -la ~/Downloads/` | P2 | Yes |
| ST-Q-ATCH-009 | After permission denied (ATCH-005), enable Location via Settings, return | Location works. Coordinates sent | P2 | Assisted |

## Manual-only tests (excluded from automated gate)

These require human interaction with iOS pickers that Appium cannot drive:

| ID | Step | Expected | Severity |
|----|------|----------|----------|
| ST-Q-ATCH-010 | Select Photos, pick 1 photo | Photo uploaded. Server confirms | P1 |
| ST-Q-ATCH-011 | Select Photos, pick 5 at once | All 5 uploaded. Progress shown | P1 |
| ST-Q-ATCH-012 | Select Camera, take photo | Photo uploaded. Camera dismissed | P1 |
| ST-Q-ATCH-013 | Select Camera, cancel | Camera dismissed. No error | P2 |
| ST-Q-ATCH-014 | Camera permission denied | Permission denied message. No crash | P1 |
