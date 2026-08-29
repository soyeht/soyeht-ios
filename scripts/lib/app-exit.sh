# Shared install-phase guard: never mutate an app bundle while any process is
# still executing from it. Replacing a running bundle invalidates the live
# process's code identity; macOS TCC then degrades folder grants for that
# process tree, silently (EPERM with no prompt and no log). Reproduced on
# 2026-08-28: an in-place swap forced re-authorization of an already granted
# Documents access, and in the product it surfaced as silent EPERM in every
# new terminal pane. The only safe order is: quit, WAIT until nothing runs
# from the bundle, then swap, then relaunch.
#
# Source this file; the functions rely only on /bin and /usr/bin tools.

# Print the PIDs whose reported command path starts with the bundle path.
# `ps -o comm=` reports argv[0], NOT the kernel's executable path, so this is
# a fast first net only — a process exec'd with a relative or rewritten
# argv[0] is invisible here, which is why soyeht_wait_app_exit confirms an
# empty scan against the kernel via lsof before trusting it. The match is
# anchored to the start of the comm field: an unrelated process whose path
# merely CONTAINS the bundle path (a mirror, a backup copy) must not be
# counted — the guard escalates with SIGTERM and must never signal a
# bystander. The prefix travels via the environment because `awk -v`
# C-escape-processes backslashes in values.
# Returns 2 when the scan itself fails; the guard refuses on that, because a
# broken scan reading as "nothing running" would approve the exact swap this
# library exists to prevent.
soyeht_pids_running_from_bundle() {
  local bundle="${1%/}"
  local snapshot
  snapshot=$(/bin/ps -axo pid=,comm=) || return 2
  printf '%s\n' "$snapshot" | SOYEHT_BUNDLE_PREFIX="$bundle/" /usr/bin/awk '
    {
      pid = $1
      line = $0
      sub(/^[ \t]*[0-9]+[ \t]+/, "", line)
      if (index(line, ENVIRON["SOYEHT_BUNDLE_PREFIX"]) == 1) print pid
    }' || return 2
}

# Kernel-truth net: PIDs holding executable (txt) mappings of files inside
# the bundle — running images, regardless of argv[0]. Restricted to txt so a
# Spotlight worker reading a plist does not block an install forever.
# lsof exits 1 both for "no matches" and for some errors; empty output with
# exit <= 1 is treated as clean, anything above as a scan failure (returns 2).
soyeht_pids_holding_bundle_text() {
  local bundle="${1%/}"
  local out rc=0
  out=$(/usr/sbin/lsof -t +D "$bundle" -a -d txt 2>/dev/null) || rc=$?
  if ((rc > 1)); then
    return 2
  fi
  printf '%s' "$out"
}

# soyeht_wait_app_exit <bundle-path> <bundle-id> [timeout-seconds]
#
# Ask the app to quit, then wait until no process runs from the bundle.
# The polite AppleEvent quit is re-sent halfway through the timeout (a first
# quit can race launch or be dropped without Automation permission) and only
# at three quarters does the guard escalate once with SIGTERM — a TERM'd app
# skips applicationWillTerminate and loses its final debounced persistence
# flush, so it is a last resort, not the opening move. Returns non-zero
# without touching anything if processes survive the full timeout or a scan
# fails: the caller MUST abort the install rather than swap under a live
# process.
soyeht_wait_app_exit() {
  local bundle="${1%/}"
  local bundle_id="$2"
  local timeout="${3:-30}"
  local deadline=$((SECONDS + timeout))
  local requit_at=$((SECONDS + timeout / 2))
  local escalate_at=$((SECONDS + (timeout * 3) / 4))
  local requited=false
  local escalated=false
  local pids holders

  # Best-effort AppleEvent quit. This can fail silently (app not running, or
  # the caller lacks Automation permission); the wait loop below is the
  # authority on whether the app actually exited.
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" \
    >/dev/null 2>&1 || true

  while :; do
    if ! pids=$(soyeht_pids_running_from_bundle "$bundle"); then
      >&2 echo "process scan failed for $bundle; refusing to install blind"
      return 1
    fi
    if [[ -z "$pids" ]]; then
      if ! holders=$(soyeht_pids_holding_bundle_text "$bundle"); then
        >&2 echo "lsof scan failed for $bundle; refusing to install blind"
        return 1
      fi
      if [[ -z "$holders" ]]; then
        return 0
      fi
      pids="$holders"
    fi
    if ((SECONDS >= deadline)); then
      >&2 echo "refusing to install over a live app: still executing from $bundle (pids: ${pids//$'\n'/ })"
      >&2 echo "quit the app (or stop those processes) and rerun the install"
      return 1
    fi
    if [[ "$requited" == false ]] && ((SECONDS >= requit_at)); then
      /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" \
        >/dev/null 2>&1 || true
      requited=true
    fi
    if [[ "$escalated" == false ]] && ((SECONDS >= escalate_at)); then
      # shellcheck disable=SC2086
      /bin/kill -TERM $pids 2>/dev/null || true
      escalated=true
    fi
    /bin/sleep 1
  done
}

# soyeht_acquire_install_lock <bundle-id>
#
# Two concurrent installs that both pass their exit-wait guards would
# interleave mv/ditto on the same destination. mkdir is the atomic
# arbiter; the caller must remove the printed directory on exit.
soyeht_acquire_install_lock() {
  local lock="/private/tmp/soyeht-install-${1}.lock"
  if ! /bin/mkdir "$lock" 2>/dev/null; then
    >&2 echo "another install of ${1} holds $lock"
    >&2 echo "rerun after it finishes, or remove the directory if it is stale"
    return 1
  fi
  printf '%s' "$lock"
}
