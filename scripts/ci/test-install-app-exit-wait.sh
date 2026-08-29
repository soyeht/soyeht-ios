#!/usr/bin/env bash
set -euo pipefail

# Red/green proof for the install-phase guard in scripts/lib/app-exit.sh.
#
# Green: a process running from the bundle that honors SIGTERM — the guard
# escalates once and returns 0 only after nothing executes from the bundle.
# Red: a TERM-immune process from the bundle — the guard must return
# non-zero and leave the process alone, so the caller aborts the install
# instead of swapping under a live process (the 2026-08-28 TCC incident).
#
# The dummy executable is compiled here (a copied system binary would be
# SIGKILLed by AMFI outside the system volume) so the process's image path
# genuinely lives inside the bundle, which is what
# soyeht_pids_running_from_bundle matches on. With any argument it ignores
# SIGTERM (the red case); without arguments it dies on SIGTERM (green).

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../lib/app-exit.sh
source "$script_dir/../lib/app-exit.sh"

tmp=$(/usr/bin/mktemp -d /private/tmp/soyeht-app-exit-test.XXXXXX)
red_pid=""
cleanup() {
  [[ -n "$red_pid" ]] && /bin/kill -KILL "$red_pid" 2>/dev/null || true
  /bin/rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  >&2 echo "FAIL: $1"
  exit 1
}

cat > "$tmp/dummy.c" <<'EOF'
#include <signal.h>
#include <unistd.h>
int main(int argc, char **argv) {
  (void)argv;
  if (argc > 1) signal(SIGTERM, SIG_IGN);
  for (;;) pause();
}
EOF
/usr/bin/clang -O0 -o "$tmp/dummy" "$tmp/dummy.c"

make_bundle() {
  /bin/mkdir -p "$1/Contents/MacOS"
  /bin/cp "$tmp/dummy" "$1/Contents/MacOS/Dummy"
}

# Control: an empty bundle (no live processes) passes immediately.
make_bundle "$tmp/Idle.app"
soyeht_wait_app_exit "$tmp/Idle.app" com.example.idle 5 \
  || fail "guard rejected a bundle with no running processes"

# Green: TERM-able process; the guard's escalation must clear it.
make_bundle "$tmp/Green.app"
"$tmp/Green.app/Contents/MacOS/Dummy" &
green_pid=$!
[[ -n "$(soyeht_pids_running_from_bundle "$tmp/Green.app")" ]] \
  || fail "pid scan missed a live process executing from the bundle"
soyeht_wait_app_exit "$tmp/Green.app" com.example.green 8 \
  || fail "guard did not succeed after SIGTERM escalation"
if /bin/kill -0 "$green_pid" 2>/dev/null; then
  fail "guard returned success while the bundle process was still alive"
fi

# Red: TERM-immune process; the guard must refuse within its timeout.
make_bundle "$tmp/Red.app"
"$tmp/Red.app/Contents/MacOS/Dummy" ignore-term &
red_pid=$!
if soyeht_wait_app_exit "$tmp/Red.app" com.example.red 6; then
  fail "guard approved an install while a TERM-immune process ran from the bundle"
fi
/bin/kill -0 "$red_pid" 2>/dev/null \
  || fail "red-case process died prematurely; the refusal was not exercised"

echo "PASS: install-phase exit-wait guard (idle, green escalation, red refusal)"
