# App Review Demo Host

Scope: verify that Apple App Review can exercise the iOS macOS-terminal mirror
without access to a personal developer Mac.

## Test Cases

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| ST-Q-AREV-001 | Demo host setup script validates safety gate | Run `scripts/app-review-demo-host.sh --setup-only` without `--confirm-disposable-host` or `--allow-current-user`. | Script exits non-zero and refuses to run against a personal account. |
| ST-Q-AREV-002 | Demo host files are created | Run `scripts/app-review-demo-host.sh --setup-only --allow-current-user --root /tmp/soyeht-app-review-demo`. | Creates `home`, `workspace`, `Automation`, `logs`, `workspace/README.txt`, and executable `bin/soyeht-review-shell`. |
| ST-Q-AREV-003 | Local shell starts in demo environment | Launch Soyeht with `SOYEHT_APP_REVIEW_DEMO_ROOT=/tmp/soyeht-app-review-demo`, open a shell pane, run `pwd`, `echo "$HOME"`, and `cat README.txt`. | `pwd` is `/tmp/soyeht-app-review-demo/workspace`; `HOME` is `/tmp/soyeht-app-review-demo/home`; README content is visible. |
| ST-Q-AREV-004 | iOS can attach to review Mac on LAN | Start disposable review Mac host, install/open iOS app, select the review Mac, attach to the shell pane, run `echo review-ok`. | iOS terminal mirrors the macOS pane and shows `review-ok`. |
| ST-Q-AREV-005 | iOS can attach through remote review route | Configure the disposable review host behind the production review route, open iOS app outside LAN, pair/select host, attach to shell pane. | iOS reaches the host without requiring the reviewer to install Tailscale or another third-party VPN. |
| ST-Q-AREV-006 | Review notes are complete | Run `scripts/app-review-demo-host.sh --setup-only --allow-current-user --print-review-notes`. | Notes include display name, reachability placeholder, steps, safe commands, and disposable-host statement. |
| ST-Q-AREV-007 | Reset removes local demo state | Run `scripts/app-review-demo-host.sh --clear-launch-env` and delete the demo root. Relaunch Soyeht normally. | Demo env vars are not inherited and normal local shell behavior is restored. |

## Automation

Automated:

- `bash -n scripts/app-review-demo-host.sh`
- `scripts/app-review-demo-host.sh --setup-only --allow-current-user --root /tmp/soyeht-app-review-demo --print-review-notes`
- SoyehtMac Debug/Release build

Assisted:

- Real iPhone pairing/attach on LAN.
- Real iPhone pairing/attach through the public App Review route.

## Release Criteria

- ST-Q-AREV-001, 002, 003, 006, and 007 must pass before submitting a build.
- ST-Q-AREV-004 must pass for a same-network review plan.
- ST-Q-AREV-005 must pass if Apple will review remotely without access to the
  same LAN.
