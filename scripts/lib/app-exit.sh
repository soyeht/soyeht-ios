# Shared install-phase guard: never mutate an app bundle while any process is
# still executing from it. Replacing a running bundle invalidates the live
# process's code identity; macOS TCC then degrades folder grants for that
# process tree, silently (EPERM with no prompt and no log). Reproduced on
# 2026-08-28: an in-place swap forced re-authorization of an already granted
# Documents access, and in the product it surfaced as silent EPERM in every
# new terminal pane. The only safe order is: quit, WAIT until nothing runs
# from the bundle, then swap, then relaunch.
#
# Source this file; both functions rely only on /bin and /usr/bin tools.

# Print the PIDs of every process whose executable lives inside the bundle.
# `ps -axo comm=` reports the full executable path on macOS, so a prefix
# match also catches bundled helpers, not only the main executable.
soyeht_pids_running_from_bundle() {
  local bundle="${1%/}"
  /bin/ps -axo pid=,comm= | /usr/bin/awk -v prefix="$bundle/" \
    'index($0, prefix) { print $1 }' 2>/dev/null || true
}

# soyeht_wait_app_exit <bundle-path> <bundle-id> [timeout-seconds]
#
# Ask the app to quit, then wait until no process runs from the bundle.
# Halfway through the timeout, escalate once with SIGTERM. Returns non-zero
# without touching anything if processes survive the full timeout: the
# caller MUST abort the install rather than swap under a live process.
soyeht_wait_app_exit() {
  local bundle="${1%/}"
  local bundle_id="$2"
  local timeout="${3:-30}"
  local deadline=$((SECONDS + timeout))
  local escalate_at=$((SECONDS + timeout / 2))
  local escalated=false
  local pids

  # Best-effort AppleEvent quit. This can fail silently (app not running, or
  # the caller lacks Automation permission); the wait loop below is the
  # authority on whether the app actually exited.
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" \
    >/dev/null 2>&1 || true

  while :; do
    pids=$(soyeht_pids_running_from_bundle "$bundle")
    if [[ -z "$pids" ]]; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      >&2 echo "refusing to install over a live app: still executing from $bundle (pids: ${pids//$'\n'/ })"
      >&2 echo "quit the app (or stop those processes) and rerun the install"
      return 1
    fi
    if [[ "$escalated" == false ]] && ((SECONDS >= escalate_at)); then
      # shellcheck disable=SC2086
      /bin/kill -TERM $pids 2>/dev/null || true
      escalated=true
    fi
    /bin/sleep 1
  done
}
