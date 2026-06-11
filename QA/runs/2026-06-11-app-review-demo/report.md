# App Review Demo Host Validation

**Date:** 2026-06-11
**Worktree:** `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm-app-review-demo`
**Branch:** `prepare-app-review-demo`

## Verdict

PASS for the macOS review-host preparation and local shell demo environment.

The real iPhone attach flow remains assisted release validation because it
depends on the actual App Review network route.

## Automated Checks

| Check | Result |
| --- | --- |
| `bash -n scripts/app-review-demo-host.sh` | PASS |
| `git diff --check` | PASS |
| Safety gate: `scripts/app-review-demo-host.sh --setup-only` without confirmation | PASS, refused to run |
| Setup: `scripts/app-review-demo-host.sh --setup-only --allow-current-user --root /tmp/soyeht-app-review-demo-script --print-review-notes` | PASS |
| Nested root setup under `/tmp/soyeht-app-review-demo-script-nested/child` | PASS |
| `swift test` in `TerminalApp/SoyehtMacTests` | PASS, 349 tests |
| `xcodebuild` Debug SoyehtMac | PASS |
| `xcodebuild` Release SoyehtMac | PASS |

## Runtime Smoke

Launched an isolated `Soyeht Dev.app` built from this worktree with:

- `SOYEHT_APP_REVIEW_DEMO_ROOT=/tmp/soyeht-app-review-demo-e2e`
- `SOYEHT_APP_REVIEW_DEMO_SHELL=/tmp/soyeht-app-review-demo-e2e/bin/soyeht-review-shell`
- `SOYEHT_WORKSPACE_STORE_URL=file:///tmp/soyeht-app-review-demo-e2e/workspaces.json`
- `SOYEHT_AUTOMATION_DIR=/tmp/soyeht-app-review-demo-e2e/Automation`

Then used Soyeht automation to open a shell pane and run:

```bash
printf "SOYEHT_REVIEW_CHECK:%s:%s\n" "$PWD" "$HOME"; cat README.txt
```

Confirmed from `capture_pane`:

- Prompt contained `soyeht-review workspace $`.
- `PWD` resolved to `/tmp/soyeht-app-review-demo-e2e/workspace`.
- `HOME` resolved to `/tmp/soyeht-app-review-demo-e2e/home`.
- `README.txt` printed `Soyeht App Review Demo`.

## Follow-Up Before Submission

- Run ST-Q-AREV-004 with a real iPhone on the same LAN.
- Run ST-Q-AREV-005 if Apple review will use a public route instead of LAN.
- Submit App Review notes with the disposable host name, route, and safe test
  commands from `docs/app-review-demo.md`.
