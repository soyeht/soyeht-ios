#!/usr/bin/env bash
set -euo pipefail

ROOT="${SOYEHT_APP_REVIEW_DEMO_ROOT:-$HOME/SoyehtReviewDemo}"
APP_PATH="${SOYEHT_APP_REVIEW_APP_PATH:-/Applications/Soyeht.app}"
PUBLIC_HOST="${SOYEHT_APP_REVIEW_PUBLIC_HOST:-}"
MAC_NAME="${SOYEHT_APP_REVIEW_MAC_NAME:-Soyeht Review Mac}"
CONFIRM_DISPOSABLE_HOST=0
ALLOW_CURRENT_USER=0
SETUP_ONLY=0
PRINT_NOTES=0
CLEAR_ENV=0

usage() {
  cat <<'EOF'
Usage:
  scripts/app-review-demo-host.sh [options]

Options:
  --app PATH                    Soyeht.app path. Default: /Applications/Soyeht.app
  --dev                         Use /Applications/Soyeht Dev.app
  --root PATH                   Demo root. Default: ~/SoyehtReviewDemo
  --public-host HOST            Public/LAN host reviewers can reach, if available
  --mac-name NAME               Display name to write into review notes
  --confirm-disposable-host     Confirm this is a dedicated review Mac/VM/user
  --allow-current-user          Local validation escape hatch; not for App Review
  --setup-only                  Prepare files/env, do not launch the app
  --print-review-notes          Print App Store Connect review notes
  --clear-launch-env            Remove launchctl env vars set by this script
  -h, --help                    Show this help

This script prepares the macOS side of the App Review demo. It does not create
a macOS account and it is not a filesystem sandbox. For App Review, run it in a
dedicated standard macOS user or disposable VM with no personal data.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || die "--app requires a path"
      APP_PATH="$2"
      shift 2
      ;;
    --dev)
      APP_PATH="/Applications/Soyeht Dev.app"
      shift
      ;;
    --root)
      [[ $# -ge 2 ]] || die "--root requires a path"
      ROOT="$2"
      shift 2
      ;;
    --public-host)
      [[ $# -ge 2 ]] || die "--public-host requires a host"
      PUBLIC_HOST="$2"
      shift 2
      ;;
    --mac-name)
      [[ $# -ge 2 ]] || die "--mac-name requires a name"
      MAC_NAME="$2"
      shift 2
      ;;
    --confirm-disposable-host)
      CONFIRM_DISPOSABLE_HOST=1
      shift
      ;;
    --allow-current-user)
      ALLOW_CURRENT_USER=1
      shift
      ;;
    --setup-only)
      SETUP_ONLY=1
      shift
      ;;
    --print-review-notes)
      PRINT_NOTES=1
      shift
      ;;
    --clear-launch-env)
      CLEAR_ENV=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "$CLEAR_ENV" == "1" ]]; then
  for key in \
    SOYEHT_APP_REVIEW_DEMO_ROOT \
    SOYEHT_APP_REVIEW_DEMO_SHELL \
    SOYEHT_APP_REVIEW_DEMO_PATH \
    SOYEHT_WORKSPACE_STORE_URL \
    SOYEHT_AUTOMATION_DIR \
    SOYEHT_LOCAL_PS1
  do
    launchctl unsetenv "$key" 2>/dev/null || true
  done
  echo "Cleared Soyeht App Review launch environment."
  exit 0
fi

if [[ "$CONFIRM_DISPOSABLE_HOST" != "1" && "$ALLOW_CURRENT_USER" != "1" ]]; then
  die "refusing to launch against a personal account. Use --confirm-disposable-host on a dedicated review Mac/VM/user, or --allow-current-user only for local validation."
fi

case "$ROOT" in
  ~) ROOT="$HOME" ;;
  ~/*) ROOT="$HOME/${ROOT#~/}" ;;
esac
ROOT_PARENT="$(dirname "$ROOT")"
ROOT_BASE="$(basename "$ROOT")"
mkdir -p "$ROOT_PARENT"
ROOT="$(cd "$ROOT_PARENT" && pwd -P)/$ROOT_BASE"

mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/workspace" "$ROOT/Automation" "$ROOT/logs"
chmod 700 "$ROOT" "$ROOT/bin" "$ROOT/home" "$ROOT/workspace" "$ROOT/Automation" "$ROOT/logs"

cat > "$ROOT/workspace/README.txt" <<EOF
Soyeht App Review Demo

This disposable workspace is safe for Apple App Review.

Try:
  pwd
  ls -la
  cat README.txt
  echo "Hello from Soyeht"
  date

This host should run inside a dedicated macOS account or VM. It should not
contain personal files, source code, signing keys, or developer credentials.
EOF

cat > "$ROOT/home/.bashrc" <<'EOF'
export HISTFILE="$SOYEHT_APP_REVIEW_DEMO_ROOT/home/.bash_history"
export PS1='\[\e[32m\]soyeht-review\[\e[0m\] \[\e[36m\]\W\[\e[0m\] $ '
cd "$SOYEHT_APP_REVIEW_DEMO_ROOT/workspace" 2>/dev/null || true
EOF

cat > "$ROOT/bin/soyeht-review-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$SOYEHT_APP_REVIEW_DEMO_ROOT/workspace" 2>/dev/null || true
exec /bin/bash --noprofile --rcfile "$SOYEHT_APP_REVIEW_DEMO_ROOT/home/.bashrc" "$@"
EOF
chmod 700 "$ROOT/bin/soyeht-review-shell"

WORKSPACE_STORE_URL="file://$ROOT/workspaces.json"
DEMO_PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DEMO_PS1='\[\e[32m\]soyeht-review\[\e[0m\] \[\e[36m\]\W\[\e[0m\] $ '

launchctl setenv SOYEHT_APP_REVIEW_DEMO_ROOT "$ROOT"
launchctl setenv SOYEHT_APP_REVIEW_DEMO_SHELL "$ROOT/bin/soyeht-review-shell"
launchctl setenv SOYEHT_APP_REVIEW_DEMO_PATH "$DEMO_PATH"
launchctl setenv SOYEHT_WORKSPACE_STORE_URL "$WORKSPACE_STORE_URL"
launchctl setenv SOYEHT_AUTOMATION_DIR "$ROOT/Automation"
launchctl setenv SOYEHT_LOCAL_PS1 "$DEMO_PS1"

if [[ "$PRINT_NOTES" == "1" ]]; then
  cat <<EOF
App Store Connect Review Notes

The iOS app mirrors a live Soyeht macOS terminal. A disposable macOS review host
is running with no personal data.

Mac display name: $MAC_NAME
Demo workspace: $ROOT/workspace
Reachability: ${PUBLIC_HOST:-same LAN or pairing link shown by the macOS app}

Steps:
1. Install and open Soyeht on iPhone.
2. Select "$MAC_NAME" from the Mac list, or use the pairing link/QR provided in
   the review notes if the device is not on the same LAN.
3. Open the visible shell pane.
4. Run safe commands such as:
   pwd
   ls -la
   cat README.txt
   echo "Hello from Soyeht"
   date

The demo host is resettable. The shell starts with HOME=$ROOT/home and
PWD=$ROOT/workspace under a dedicated review account/VM.
EOF
fi

echo "Prepared Soyeht App Review demo root: $ROOT"
echo "Workspace: $ROOT/workspace"
echo "Automation dir: $ROOT/Automation"

if [[ "$SETUP_ONLY" == "1" ]]; then
  echo "Setup-only mode: not launching app."
  exit 0
fi

[[ -d "$APP_PATH" ]] || die "app not found: $APP_PATH"
open -n "$APP_PATH"
echo "Launched: $APP_PATH"
