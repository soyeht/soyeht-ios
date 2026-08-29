#!/usr/bin/env bash
set -euo pipefail

# Red/green proof for the install-phase guard in scripts/lib/app-exit.sh.
#
# Green: a process running from the bundle that honors SIGTERM — the guard
# escalates once and returns 0 only after nothing executes from the bundle.
# Red: a TERM-immune process from the bundle — the guard must return
# non-zero and leave the process alone, so the caller aborts the install
# instead of swapping under a live process (the 2026-08-28 TCC incident).
# Bystander: a process whose path merely CONTAINS the bundle path must be
# invisible to the guard — it escalates with SIGTERM and must never signal
# an unrelated process.
# Relative argv[0]: `ps -o comm=` reports argv[0], so a process exec'd as
# `./Dummy` is invisible to the ps net; the lsof kernel net must still see
# it, or the guard approves the exact swap it exists to prevent.
#
# The dummy executable is compiled here (a copied system binary would be
# SIGKILLed by AMFI outside the system volume) so the process's image path
# genuinely lives inside the bundle. With any argument it ignores SIGTERM
# (the red case); without arguments it dies on SIGTERM (green).

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../lib/app-exit.sh
source "$script_dir/../lib/app-exit.sh"

tmp=$(/usr/bin/mktemp -d /private/tmp/soyeht-app-exit-test.XXXXXX)
spawned_pids=()
cleanup() {
  for pid in "${spawned_pids[@]:-}"; do
    [[ -n "$pid" ]] && /bin/kill -KILL "$pid" 2>/dev/null || true
  done
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

# Poll until the ps net sees a process for the bundle: asserting right after
# the spawn races the child's exec and flakes.
await_ps_visibility() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -n "$(soyeht_pids_running_from_bundle "$1")" ]] && return 0
    /bin/sleep 0.3
  done
  return 1
}

# --- Control: an empty bundle (no live processes) passes immediately.
make_bundle "$tmp/Idle.app"
soyeht_wait_app_exit "$tmp/Idle.app" com.example.idle 5 \
  || fail "guard rejected a bundle with no running processes"

# --- Green: TERM-able process; the guard's escalation must clear it.
make_bundle "$tmp/Green.app"
"$tmp/Green.app/Contents/MacOS/Dummy" &
green_pid=$!
spawned_pids+=("$green_pid")
await_ps_visibility "$tmp/Green.app" \
  || fail "pid scan missed a live process executing from the bundle"
soyeht_wait_app_exit "$tmp/Green.app" com.example.green 8 \
  || fail "guard did not succeed after SIGTERM escalation"
if /bin/kill -0 "$green_pid" 2>/dev/null; then
  fail "guard returned success while the bundle process was still alive"
fi

# --- Bystander: path contains the bundle path but is not the bundle.
make_bundle "$tmp/Real.app"
mirror="$tmp/mirror$tmp/Real.app"
make_bundle "$mirror"
"$mirror/Contents/MacOS/Dummy" &
mirror_pid=$!
spawned_pids+=("$mirror_pid")
await_ps_visibility "$mirror" \
  || fail "mirror process never became visible; bystander case not exercised"
[[ -z "$(soyeht_pids_running_from_bundle "$tmp/Real.app")" ]] \
  || fail "pid scan matched a bystander whose path merely contains the bundle path"
soyeht_wait_app_exit "$tmp/Real.app" com.example.real 5 \
  || fail "guard refused an idle bundle because of a bystander process"
/bin/kill -0 "$mirror_pid" 2>/dev/null \
  || fail "guard signalled a bystander process it must never touch"
/bin/kill -KILL "$mirror_pid" 2>/dev/null || true

# --- Relative argv[0]: invisible to ps, caught by the lsof kernel net.
make_bundle "$tmp/Rel.app"
(cd "$tmp/Rel.app/Contents/MacOS" && exec ./Dummy) &
rel_pid=$!
spawned_pids+=("$rel_pid")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -n "$(soyeht_pids_holding_bundle_text "$tmp/Rel.app")" ]] && break
  /bin/sleep 0.3
done
[[ -z "$(soyeht_pids_running_from_bundle "$tmp/Rel.app")" ]] \
  || fail "expected the relative-argv0 process to be invisible to the ps net"
[[ -n "$(soyeht_pids_holding_bundle_text "$tmp/Rel.app")" ]] \
  || fail "lsof net missed a process executing from the bundle via relative argv[0]"
soyeht_wait_app_exit "$tmp/Rel.app" com.example.rel 8 \
  || fail "guard did not clear a relative-argv0 process via the lsof net"
if /bin/kill -0 "$rel_pid" 2>/dev/null; then
  fail "guard returned success while the relative-argv0 process was still alive"
fi

# --- Multi-pid escalation: both processes must receive the SIGTERM.
make_bundle "$tmp/Multi.app"
"$tmp/Multi.app/Contents/MacOS/Dummy" &
multi_a=$!
"$tmp/Multi.app/Contents/MacOS/Dummy" &
multi_b=$!
spawned_pids+=("$multi_a" "$multi_b")
await_ps_visibility "$tmp/Multi.app" \
  || fail "multi-pid processes never became visible"
soyeht_wait_app_exit "$tmp/Multi.app" com.example.multi 8 \
  || fail "guard did not clear multiple bundle processes"
if /bin/kill -0 "$multi_a" 2>/dev/null || /bin/kill -0 "$multi_b" 2>/dev/null; then
  fail "guard returned success with a bundle process still alive (multi-pid)"
fi

# --- Red: TERM-immune process; the guard must refuse within its timeout.
make_bundle "$tmp/Red.app"
"$tmp/Red.app/Contents/MacOS/Dummy" ignore-term &
red_pid=$!
spawned_pids+=("$red_pid")
await_ps_visibility "$tmp/Red.app" \
  || fail "red-case process never became visible"
if soyeht_wait_app_exit "$tmp/Red.app" com.example.red 6; then
  fail "guard approved an install while a TERM-immune process ran from the bundle"
fi
/bin/kill -0 "$red_pid" 2>/dev/null \
  || fail "red-case process died prematurely; the refusal was not exercised"

# --- Install lock: second acquisition must fail while the first is held.
lock_dir=$(soyeht_acquire_install_lock com.example.lock) \
  || fail "first lock acquisition failed"
if soyeht_acquire_install_lock com.example.lock >/dev/null 2>&1; then
  fail "second concurrent lock acquisition succeeded"
fi
/bin/rmdir "$lock_dir"
lock_dir=$(soyeht_acquire_install_lock com.example.lock) \
  || fail "lock is not reacquirable after release"
/bin/rmdir "$lock_dir"

echo "PASS: install-phase exit-wait guard (idle, green escalation, bystander, relative argv0, multi-pid, red refusal, lock)"
