#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
AUTO_YES=false
KEEP_APP=false
APP_PATHS=()
FAILURES=()

usage() {
    cat <<'EOF'
Usage: scripts/uninstall-soyeht-macos.sh [--yes] [--dry-run] [--keep-app] [--app PATH]

Removes the macOS Soyeht app, embedded engine, legacy theyOS Homebrew state,
MCP launcher/config entries, LaunchAgents, user caches/logs, and Soyeht
keychain rows. The script intentionally does not remove ~/.soyeht because this
developer machine uses it for release/notary/APNs credentials, not product
runtime state.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --yes|-y) AUTO_YES=true ;;
        --keep-app) KEEP_APP=true ;;
        --app)
            shift
            [ "$#" -gt 0 ] || { echo "[error] --app requires a path" >&2; exit 2; }
            APP_PATHS+=("$1")
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[error] unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

log() { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }

quote_cmd() {
    local out=()
    local arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out+=("$arg")
    done
    printf '%s' "${out[*]}"
}

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        printf '[dry-run] %s\n' "$(quote_cmd "$@")"
        return 0
    fi
    "$@"
}

can_sudo() {
    command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

best_effort() {
    if ! run_cmd "$@"; then
        warn "command failed: $(quote_cmd "$@")"
        return 1
    fi
}

remove_path() {
    local path="$1"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        printf '[dry-run] rm -rf %q\n' "$path"
        return 0
    fi
    if rm -rf "$path"; then
        log "removed $path"
    elif can_sudo && sudo rm -rf "$path"; then
        log "removed $path with sudo"
    else
        warn "could not remove $path"
        FAILURES+=("$path")
    fi
}

remove_glob() {
    local matched=false
    local path
    for path in "$@"; do
        matched=true
        remove_path "$path"
    done
    [ "$matched" = true ] || true
}

remove_find_matches() {
    local root="$1"
    shift
    [ -d "$root" ] || return 0
    while IFS= read -r -d '' path; do
        remove_path "$path"
    done < <(find "$root" "$@" -print0 2>/dev/null || true)
}

confirm() {
    [ "$AUTO_YES" = true ] && return 0
    [ "$DRY_RUN" = true ] && return 0
    printf 'This will remove Soyeht/theyOS runtime state from this Mac. Type "uninstall" to continue: '
    read -r answer
    [ "$answer" = "uninstall" ] || { echo "Aborted."; exit 1; }
}

launchctl_stop() {
    local label="$1"
    local uid
    uid="$(id -u)"
    best_effort /bin/launchctl bootout "gui/$uid/$label" || true
    best_effort /bin/launchctl remove "$label" || true
}

stop_processes() {
    if command -v osascript >/dev/null 2>&1; then
        best_effort osascript -e 'tell application "Soyeht" to quit' || true
    fi
    launchctl_stop com.soyeht.engine
    launchctl_stop com.soyeht.caddy
    launchctl_stop com.theyos.cloudflared

    if command -v brew >/dev/null 2>&1; then
        best_effort brew services stop theyos || true
    fi
    best_effort pkill -TERM -f '/Library/Application Support/Soyeht/engine/' || true
    best_effort pkill -TERM -f 'theyos-engine' || true
    sleep 1
    best_effort pkill -KILL -f '/Library/Application Support/Soyeht/engine/' || true
    best_effort pkill -KILL -f 'theyos-engine' || true
}

clean_mcp_configs() {
    local py
    py="$(command -v python3 || true)"
    if [ -z "$py" ]; then
        warn "python3 not found; MCP config cleanup skipped"
        return 0
    fi

    "$py" - "$HOME" "$DRY_RUN" <<'PY'
import json
import pathlib
import re
import sys

home = pathlib.Path(sys.argv[1])
dry_run = sys.argv[2] == "true"

def rewrite_json(path, mutator):
    if not path.exists():
        return
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        print(f"[warn] could not parse {path}: {exc}", file=sys.stderr)
        return
    changed = mutator(data)
    if not changed:
        return
    if dry_run:
        print(f"[dry-run] remove Soyeht MCP entry from {path}")
        return
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    print(f"[mcp] removed Soyeht entry from {path}")

def remove_key(container, key):
    if isinstance(container, dict) and key in container:
        del container[key]
        return True
    return False

rewrite_json(
    home / ".claude.json",
    lambda root: remove_key(root.get("mcpServers"), "soyeht") if isinstance(root, dict) else False,
)
rewrite_json(
    home / ".factory" / "mcp.json",
    lambda root: remove_key(root.get("mcpServers"), "soyeht") if isinstance(root, dict) else False,
)
rewrite_json(
    home / ".config" / "opencode" / "opencode.json",
    lambda root: remove_key(root.get("mcp"), "soyeht") if isinstance(root, dict) else False,
)

codex = home / ".codex" / "config.toml"
if codex.exists():
    text = codex.read_text()
    new = re.sub(r"(?ms)^\[mcp_servers\.soyeht(?:\.[^\]]*)?\][^\[]*", "", text)
    if new != text:
        if dry_run:
            print(f"[dry-run] remove Soyeht MCP entry from {codex}")
        else:
            codex.write_text(new.rstrip() + "\n")
            print(f"[mcp] removed Soyeht entry from {codex}")
PY
}

clean_keychain() {
    local helper="$SCRIPT_DIR/uninstall-soyeht-macos-keychain.swift"
    if [ ! -f "$helper" ]; then
        warn "keychain helper missing: $helper"
        return 0
    fi
    if ! command -v swift >/dev/null 2>&1; then
        warn "swift not found; keychain cleanup skipped"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        swift "$helper" --dry-run || warn "keychain dry-run failed"
    else
        best_effort swift "$helper" || true
    fi
}

remove_files() {
    local tmp="${TMPDIR:-/tmp}"
    case "$tmp" in
        */) ;;
        *) tmp="$tmp/" ;;
    esac

    if [ "$KEEP_APP" = false ]; then
        APP_PATHS+=("/Applications/Soyeht.app" "$HOME/Applications/Soyeht.app")
        APP_PATHS+=("/Applications/Soyeht Dev.app" "$HOME/Applications/Soyeht Dev.app")
        APP_PATHS+=("/Applications/theyOS.app" "$HOME/Applications/theyOS.app")
        local app
        for app in "${APP_PATHS[@]}"; do
            remove_path "$app"
        done
    fi

    local paths=(
        "$HOME/Library/Application Support/Soyeht"
        "$HOME/Library/Application Support/Soyeht QA Backups"
        "$HOME/Library/Application Support/theyos"
        "$HOME/Library/Caches/com.soyeht.mac"
        "$HOME/Library/Caches/com.soyeht.mac.dev"
        "$HOME/Library/Caches/Soyeht"
        "$HOME/Library/Caches/theyos"
        "${XDG_CACHE_HOME:-$HOME/.cache}/theyos"
        "$HOME/Library/HTTPStorages/com.soyeht.mac"
        "$HOME/Library/HTTPStorages/com.soyeht.mac.dev"
        "$HOME/Library/Logs/Soyeht"
        "$HOME/Library/Logs/theyos"
        "$HOME/Library/Preferences/com.soyeht.mac.plist"
        "$HOME/Library/Preferences/com.soyeht.mac.dev.plist"
        "$HOME/Library/Saved Application State/com.soyeht.mac.savedState"
        "$HOME/Library/Saved Application State/com.soyeht.mac.dev.savedState"
        "$HOME/Library/WebKit/com.soyeht.mac"
        "$HOME/Library/WebKit/com.soyeht.mac.dev"
        "$HOME/Library/LaunchAgents/com.soyeht.engine.plist"
        "$HOME/Library/LaunchAgents/com.soyeht.caddy.plist"
        "$HOME/Library/LaunchAgents/com.theyos.cloudflared.plist"
        "$HOME/.local/bin/soyeht-mcp"
        "$HOME/.theyos"
        "/opt/homebrew/opt/theyos"
        "/opt/homebrew/Cellar/theyos"
        "/opt/homebrew/var/log/theyos.log"
        "/usr/local/opt/theyos"
        "/usr/local/Cellar/theyos"
        "/usr/local/var/log/theyos.log"
        "/tmp/soyeht-engine.log"
        "/tmp/theyos.db"
        "/tmp/theyos.db-shm"
        "/tmp/theyos.db-wal"
        "/tmp/theyos-sessions.db"
        "/tmp/theyos-sessions.db-shm"
        "/tmp/theyos-sessions.db-wal"
        "${tmp}soyeht-engine.log"
        "${tmp}theyos.db"
        "${tmp}theyos.db-shm"
        "${tmp}theyos.db-wal"
        "${tmp}theyos-sessions.db"
        "${tmp}theyos-sessions.db-shm"
        "${tmp}theyos-sessions.db-wal"
    )

    local path
    for path in "${paths[@]}"; do
        remove_path "$path"
    done
    remove_glob "$HOME/Library/Cookies/com.soyeht.mac"* "$HOME/Library/Preferences/com.soyeht.mac."*
    remove_glob "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.soyeht."*.sfl*
    remove_glob "$HOME/Library/Preferences/com.soyeht.core.tests."*
    remove_glob "$HOME/Library/Preferences/com.soyeht.tests."*
    remove_glob "$HOME/Library/Preferences/soyeht.tests."*
    remove_glob "$HOME/Library/Application Support/CrashReporter/Soyeht"*
    remove_glob "$HOME/Library/Application Support/CrashReporter/Soyeht Dev"*
    remove_glob "$HOME/Library/Application Support/CrashReporter/theyos-engine"*
    remove_glob "$HOME/Library/Logs/DiagnosticReports/Soyeht"*
    remove_glob "$HOME/Library/Logs/DiagnosticReports/Soyeht Dev"*
    remove_glob "$HOME/Library/Logs/DiagnosticReports/ExcUserFault_Soyeht"*
    remove_glob "$HOME/Library/Logs/DiagnosticReports/theyos-engine"*
    remove_find_matches "$HOME/Library/Caches/claude-cli-nodejs" -type d -name mcp-logs-soyeht -prune
    remove_find_matches "$HOME/Library/Caches/Sparkle_generate_appcast" -type d -name Soyeht.app -prune
}

verify_no_residuals() {
    local residuals=()
    local paths=(
        "$HOME/Library/Application Support/Soyeht"
        "$HOME/Library/Application Support/Soyeht QA Backups"
        "$HOME/Library/Application Support/theyos"
        "$HOME/Library/Logs/theyos"
        "$HOME/Library/Logs/Soyeht"
        "$HOME/Library/Caches/theyos"
        "${XDG_CACHE_HOME:-$HOME/.cache}/theyos"
        "$HOME/Library/Caches/com.soyeht.mac"
        "$HOME/Library/Caches/com.soyeht.mac.dev"
        "$HOME/Library/LaunchAgents/com.soyeht.engine.plist"
        "$HOME/Library/LaunchAgents/com.soyeht.caddy.plist"
        "$HOME/Library/LaunchAgents/com.theyos.cloudflared.plist"
        "$HOME/.local/bin/soyeht-mcp"
        "$HOME/.theyos"
        "/opt/homebrew/opt/theyos"
        "/opt/homebrew/Cellar/theyos"
        "/usr/local/opt/theyos"
        "/usr/local/Cellar/theyos"
    )
    local path
    for path in "${paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            residuals+=("$path")
        fi
    done

    if ps -axo command= | grep -E '/Library/Application Support/Soyeht/engine/|theyos-engine' | grep -v grep >/dev/null; then
        residuals+=("running Soyeht/theyOS engine process")
    fi

    while IFS= read -r -d '' path; do
        residuals+=("$path")
    done < <(find "$HOME/Library/Caches/claude-cli-nodejs" -type d -name mcp-logs-soyeht -print0 2>/dev/null || true)
    while IFS= read -r -d '' path; do
        residuals+=("$path")
    done < <(find "$HOME/Library/Caches/Sparkle_generate_appcast" -type d -name Soyeht.app -print0 2>/dev/null || true)

    if [ "${#FAILURES[@]}" -gt 0 ]; then
        residuals+=("${FAILURES[@]}")
    fi
    if [ "${#residuals[@]}" -gt 0 ]; then
        printf '[error] residual Soyeht/theyOS artifacts remain:\n' >&2
        printf '  %s\n' "${residuals[@]}" >&2
        return 1
    fi
    log "verification passed: no known Soyeht/theyOS runtime artifacts remain"
}

main() {
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "[error] this uninstaller is macOS-only" >&2
        exit 2
    fi
    confirm
    stop_processes
    clean_mcp_configs
    clean_keychain
    remove_files
    if [ "$DRY_RUN" = false ]; then
        verify_no_residuals
    fi
    log "done"
}

main "$@"
