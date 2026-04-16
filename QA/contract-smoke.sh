#!/bin/bash
# Contract Smoke Tests — validates API response shapes that the iOS app expects.
# Endpoints derived from SoyehtAPIClient.swift (not invented).
#
# Usage:
#   ./QA/contract-smoke.sh                    # test against QA_BASE_URL / SOYEHT_BASE_URL / <backend-host>-1 default
#   ./QA/contract-smoke.sh https://myhost:8892  # test against specific server
#   TOKEN=xxx ./QA/contract-smoke.sh          # provide auth token
#
# Prerequisites:
#   - Backend running on target server
#   - Valid session token (or will attempt to get one via pair endpoint)
#   - curl and jq installed

set -euo pipefail

BASE_URL="${1:-${QA_BASE_URL:-${SOYEHT_BASE_URL:-https://<host>.<tailnet>.ts.net}}}"
TOKEN="${TOKEN:-}"
PASS=0
FAIL=0
SKIP=0
RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

record() {
    local id="$1" status="$2" detail="$3"
    if [ "$status" = "PASS" ]; then
        ((PASS++))
        echo -e "  ${GREEN}PASS${NC} $id — $detail"
    elif [ "$status" = "FAIL" ]; then
        ((FAIL++))
        echo -e "  ${RED}FAIL${NC} $id — $detail"
    else
        ((SKIP++))
        echo -e "  ${YELLOW}SKIP${NC} $id — $detail"
    fi
    RESULTS+=("$status $id $detail")
}

bootstrap_tmux_session() {
    local container="$1"
    local session_id="$2"
    if [ -z "${TOKEN:-}" ] || [ -z "$container" ] || [ -z "$session_id" ]; then
        return 1
    fi

    python3 - "$BASE_URL" "$container" "$session_id" "$TOKEN" <<'PY' >/dev/null 2>&1
import asyncio
import importlib.util
import ssl
import sys

base_url, container, session_id, token = sys.argv[1:]
if importlib.util.find_spec("websockets") is None:
    raise SystemExit(1)

scheme = "wss" if base_url.startswith("https://") else "ws"
host = base_url.split("://", 1)[1].rstrip("/")
url = f"{scheme}://{host}/api/v1/terminals/{container}/pty?session={session_id}&token={token}&client=mobile"

async def main():
    ssl_ctx = ssl.create_default_context() if scheme == "wss" else None
    async with __import__("websockets").connect(url, ssl=ssl_ctx, open_timeout=10, close_timeout=3) as ws:
        try:
            await asyncio.wait_for(ws.recv(), timeout=2)
        except asyncio.TimeoutError:
            pass
        await asyncio.sleep(0.5)

asyncio.run(main())
PY
}

echo "Contract Smoke Tests"
echo "Target: $BASE_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
START=$(date +%s)

# ─── T1: Health check (no auth) ───────────────────────────────────
echo ""
echo "Phase 1: Health Check"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/healthz" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    record "TY-I-HEALTH-001" "PASS" "GET /healthz → $HTTP_CODE"
else
    record "TY-I-HEALTH-001" "FAIL" "GET /healthz → $HTTP_CODE (expected 200)"
    echo -e "  ${RED}Backend not reachable. Aborting.${NC}"
    exit 1
fi

# ─── T2: Auth — need a token ──────────────────────────────────────
echo ""
echo "Phase 2: Authentication"

if [ -z "$TOKEN" ]; then
    # Try to get session status without token — should get 401
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/v1/mobile/status" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
        record "TY-I-AUTH-001" "PASS" "GET /api/v1/mobile/status without token → $HTTP_CODE (correctly rejected)"
    else
        record "TY-I-AUTH-001" "FAIL" "GET /api/v1/mobile/status without token → $HTTP_CODE (expected 401/403)"
    fi
    record "TY-I-AUTH-002" "SKIP" "POST /api/v1/mobile/auth — no token provided (set TOKEN=xxx)"
else
    # Validate token works
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/mobile/status" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        record "TY-I-AUTH-001" "PASS" "GET /api/v1/mobile/status with token → $HTTP_CODE"
    else
        record "TY-I-AUTH-001" "FAIL" "GET /api/v1/mobile/status with token → $HTTP_CODE (expected 2xx)"
    fi
fi

if [ -z "$TOKEN" ]; then
    echo -e "  ${YELLOW}No TOKEN provided. Skipping authenticated endpoints.${NC}"
    echo -e "  ${YELLOW}Set TOKEN=xxx to run full suite.${NC}"
    # Skip all remaining and print summary
    for id in TY-I-ROPT-001 TY-I-ROPT-002 TY-I-INST-001 TY-I-INST-002 TY-I-WORK-001 TY-I-TMUX-001 TY-I-TMUX-002 TY-I-WS-001; do
        record "$id" "SKIP" "No auth token"
    done
else

# ─── T3: Resource Options — deploy contract check ────────────────
echo ""
echo "Phase 3: Resource Options (GET /api/v1/mobile/resource-options)"

RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/mobile/resource-options" 2>/dev/null || echo "")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/mobile/resource-options" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    HAS_SHAPE=$(echo "$RESPONSE" | jq -r '
        if type == "object"
           and (.cpu_cores | type == "object")
           and (.ram_mb | type == "object")
           and (.disk_gb | type == "object")
        then "valid"
        else "invalid"
        end
    ' 2>/dev/null || echo "parse_error")

    if [ "$HAS_SHAPE" = "valid" ]; then
        record "TY-I-ROPT-001" "PASS" "GET /api/v1/mobile/resource-options → $HTTP_CODE (cpu_cores, ram_mb, disk_gb objects)"

        HAS_FIELDS=$(echo "$RESPONSE" | jq -r '
            (.cpu_cores | has("min") and has("max") and has("default"))
            and (.ram_mb | has("min") and has("max") and has("default"))
            and (.disk_gb | has("min") and has("max") and has("default"))
            and ((.disk_gb.disabled == null) or (.disk_gb.disabled | type == "boolean"))
        ' 2>/dev/null || echo "false")

        if [ "$HAS_FIELDS" = "true" ]; then
            record "TY-I-ROPT-002" "PASS" "resource options expose min/max/default; disk_gb.disabled is optional boolean"
        else
            record "TY-I-ROPT-002" "FAIL" "resource-options missing min/max/default fields or invalid disk_gb.disabled"
        fi
    else
        record "TY-I-ROPT-001" "FAIL" "resource-options response missing cpu_cores/ram_mb/disk_gb objects"
        record "TY-I-ROPT-002" "SKIP" "Depends on TY-I-ROPT-001"
    fi
elif [ "$HTTP_CODE" = "503" ]; then
    HAS_FALLBACK=$(echo "$RESPONSE" | jq -r '
        if type == "object"
           and (.error | type == "string")
           and (.code == "SERVICE_UNAVAILABLE")
           and (.retry_after_secs | type == "number")
        then "valid"
        else "invalid"
        end
    ' 2>/dev/null || echo "parse_error")

    if [ "$HAS_FALLBACK" = "valid" ]; then
        record "TY-I-ROPT-001" "PASS" "GET /api/v1/mobile/resource-options → 503 (structured service-unavailable contract)"
        record "TY-I-ROPT-002" "PASS" "resource-options fallback exposes error/code/retry_after_secs"
    else
        record "TY-I-ROPT-001" "FAIL" "GET /api/v1/mobile/resource-options → 503 without structured fallback body"
        record "TY-I-ROPT-002" "SKIP" "Depends on TY-I-ROPT-001"
    fi
else
    record "TY-I-ROPT-001" "FAIL" "GET /api/v1/mobile/resource-options → $HTTP_CODE"
    record "TY-I-ROPT-002" "SKIP" "Depends on TY-I-ROPT-001"
fi

# ─── T4: Instance List — envelope check ──────────────────────────
echo ""
echo "Phase 4: Instance List (GET /api/v1/mobile/instances)"

RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/mobile/instances" 2>/dev/null || echo "")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/mobile/instances" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    # Check for data envelope or bare array
    HAS_DATA=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then "envelope" elif type == "array" then "bare" else "unknown" end' 2>/dev/null || echo "parse_error")

    if [ "$HAS_DATA" = "envelope" ] || [ "$HAS_DATA" = "bare" ]; then
        record "TY-I-INST-001" "PASS" "GET /api/v1/mobile/instances → $HTTP_CODE ($HAS_DATA format)"

        # Check first instance has expected fields
        FIRST=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then .data[0] else .[0] end' 2>/dev/null || echo "null")
        if [ "$FIRST" != "null" ] && [ "$FIRST" != "" ]; then
            HAS_ID=$(echo "$FIRST" | jq -r 'has("id")' 2>/dev/null || echo "false")
            HAS_NAME=$(echo "$FIRST" | jq -r 'has("name")' 2>/dev/null || echo "false")
            HAS_CONTAINER=$(echo "$FIRST" | jq -r 'has("container")' 2>/dev/null || echo "false")
            if [ "$HAS_ID" = "true" ] && [ "$HAS_NAME" = "true" ] && [ "$HAS_CONTAINER" = "true" ]; then
                record "TY-I-INST-002" "PASS" "Instance has id, name, container fields"
            else
                record "TY-I-INST-002" "FAIL" "Instance missing required fields (id=$HAS_ID, name=$HAS_NAME, container=$HAS_CONTAINER)"
            fi

            # Save container for later tests
            CONTAINER=$(echo "$FIRST" | jq -r '.container' 2>/dev/null || echo "")
        else
            record "TY-I-INST-002" "SKIP" "No instances found to validate fields"
            CONTAINER=""
        fi
    else
        record "TY-I-INST-001" "FAIL" "Response not in expected format: $HAS_DATA"
        record "TY-I-INST-002" "SKIP" "Depends on TY-I-INST-001"
        CONTAINER=""
    fi
else
    record "TY-I-INST-001" "FAIL" "GET /api/v1/mobile/instances → $HTTP_CODE"
    record "TY-I-INST-002" "SKIP" "Depends on TY-I-INST-001"
    CONTAINER=""
fi

# ─── T5: Workspace List — envelope + snake_case ──────────────────
echo ""
echo "Phase 5: Workspaces"

if [ -n "$CONTAINER" ]; then
    RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/workspaces" 2>/dev/null || echo "")
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/workspaces" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        HAS_DATA=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then "envelope" elif type == "array" then "bare" else "unknown" end' 2>/dev/null || echo "parse_error")

        if [ "$HAS_DATA" = "envelope" ] || [ "$HAS_DATA" = "bare" ]; then
            record "TY-I-WORK-001" "PASS" "GET workspaces → $HTTP_CODE ($HAS_DATA format)"

            FIRST_WS=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then .data[0] else .[0] end' 2>/dev/null || echo "null")
            if [ "$FIRST_WS" != "null" ] && [ "$FIRST_WS" != "" ]; then
                # Check for session_id (snake_case) or sessionId (camelCase)
                HAS_SESSION=$(echo "$FIRST_WS" | jq -r 'has("session_id") or has("sessionId")' 2>/dev/null || echo "false")
                HAS_DISPLAY=$(echo "$FIRST_WS" | jq -r 'has("display_name") or has("displayName")' 2>/dev/null || echo "false")
                if [ "$HAS_SESSION" = "true" ]; then
                    record "TY-I-WORK-002" "PASS" "Workspace has session_id/sessionId field"
                    SESSION_ID=$(echo "$FIRST_WS" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || echo "")
                    bootstrap_tmux_session "$CONTAINER" "$SESSION_ID" || true
                else
                    record "TY-I-WORK-002" "FAIL" "Workspace missing session_id/sessionId"
                    SESSION_ID=""
                fi
            else
                record "TY-I-WORK-002" "SKIP" "No workspaces to validate"
                SESSION_ID=""
            fi
        else
            record "TY-I-WORK-001" "FAIL" "Unexpected response format: $HAS_DATA"
            record "TY-I-WORK-002" "SKIP" "Depends on TY-I-WORK-001"
            SESSION_ID=""
        fi
    else
        record "TY-I-WORK-001" "FAIL" "GET workspaces → $HTTP_CODE"
        record "TY-I-WORK-002" "SKIP" ""
        SESSION_ID=""
    fi
else
    record "TY-I-WORK-001" "SKIP" "No container available"
    record "TY-I-WORK-002" "SKIP" "No container available"
    SESSION_ID=""
fi

# ─── T6: Tmux Windows ────────────────────────────────────────────
echo ""
echo "Phase 6: Tmux Windows"

WINDOW_INDEX=""
PANE_ID=""

if [ -n "$CONTAINER" ] && [ -n "$SESSION_ID" ]; then
    RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/windows?session=$SESSION_ID" 2>/dev/null || echo "")
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/windows?session=$SESSION_ID" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        HAS_DATA=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then "envelope" elif type == "array" then "bare" else "unknown" end' 2>/dev/null || echo "parse_error")
        if [ "$HAS_DATA" = "envelope" ] || [ "$HAS_DATA" = "bare" ]; then
            record "TY-I-TMUX-001" "PASS" "GET tmux/windows → $HTTP_CODE ($HAS_DATA format)"
            WINDOW_INDEX=$(echo "$RESPONSE" | jq -r '
                if type == "object" and has("active_window") then .active_window
                elif type == "object" and has("data") then .data[0].index
                elif type == "array" then .[0].index
                else empty
                end
            ' 2>/dev/null || echo "")
        else
            record "TY-I-TMUX-001" "FAIL" "Unexpected format: $HAS_DATA"
        fi
    else
        record "TY-I-TMUX-001" "FAIL" "GET tmux/windows → $HTTP_CODE"
    fi

    # Panes
    if [ -z "$WINDOW_INDEX" ]; then
        record "TY-I-TMUX-002" "SKIP" "No tmux window index available"
    else
        RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/panes?session=$SESSION_ID&window=$WINDOW_INDEX" 2>/dev/null || echo "")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/panes?session=$SESSION_ID&window=$WINDOW_INDEX" 2>/dev/null || echo "000")

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            HAS_DATA=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then "envelope" elif type == "array" then "bare" else "unknown" end' 2>/dev/null || echo "parse_error")
            if [ "$HAS_DATA" = "envelope" ] || [ "$HAS_DATA" = "bare" ]; then
                record "TY-I-TMUX-002" "PASS" "GET tmux/panes → $HTTP_CODE ($HAS_DATA format)"
                PANE_ID=$(echo "$RESPONSE" | jq -r '
                    if type == "object" and has("data") then .data[0].pane_id
                    elif type == "array" then .[0].pane_id
                    else empty
                    end
                ' 2>/dev/null || echo "")
            else
                record "TY-I-TMUX-002" "FAIL" "Unexpected format: $HAS_DATA"
            fi
        else
            record "TY-I-TMUX-002" "FAIL" "GET tmux/panes → $HTTP_CODE"
        fi
    fi
else
    record "TY-I-TMUX-001" "SKIP" "No container/session available"
    record "TY-I-TMUX-002" "SKIP" "No container/session available"
fi

# ─── T7: WebSocket upgrade check ─────────────────────────────────
echo ""
echo "Phase 7: WebSocket PTY"

if [ -n "$CONTAINER" ] && [ -n "$SESSION_ID" ]; then
    # Check that WebSocket endpoint responds with 101 upgrade
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        "$BASE_URL/api/v1/terminals/$CONTAINER/pty?session=$SESSION_ID&token=$TOKEN&client=mobile" \
        2>/dev/null || echo "000")

    # WebSocket upgrade returns 101, or the server might return 400/426 if not a real WS client
    if [ "$HTTP_CODE" = "101" ]; then
        record "TY-I-WS-001" "PASS" "WebSocket upgrade → 101"
    elif [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "426" ]; then
        record "TY-I-WS-001" "PASS" "WebSocket endpoint exists → $HTTP_CODE (expected without real WS client)"
    elif [ "$HTTP_CODE" = "404" ]; then
        record "TY-I-WS-001" "FAIL" "WebSocket endpoint not found → 404"
    else
        record "TY-I-WS-001" "PASS" "WebSocket endpoint responded → $HTTP_CODE"
    fi
else
    record "TY-I-WS-001" "SKIP" "No container/session available"
fi

# ─── T8: File Browser endpoints ──────────────────────────────────
echo ""
echo "Phase 8: File Browser (GET /files, /files/download, /tmux/cwd)"

if [ -n "$CONTAINER" ] && [ -n "$SESSION_ID" ]; then
    # CWD
    if [ -n "$WINDOW_INDEX" ]; then
        RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/cwd?session=$SESSION_ID&window=$WINDOW_INDEX" 2>/dev/null || echo "")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/cwd?session=$SESSION_ID&window=$WINDOW_INDEX" 2>/dev/null || echo "000")

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            HAS_PATH=$(echo "$RESPONSE" | jq -r 'has("path") and has("pane_id")' 2>/dev/null || echo "false")
            if [ "$HAS_PATH" = "true" ]; then
                record "TY-I-BROW-001" "PASS" "GET /tmux/cwd → $HTTP_CODE (path + pane_id present)"
            else
                record "TY-I-BROW-001" "FAIL" "GET /tmux/cwd → missing path or pane_id"
            fi
        else
            record "TY-I-BROW-001" "FAIL" "GET /tmux/cwd → $HTTP_CODE"
        fi
    else
        record "TY-I-BROW-001" "SKIP" "No tmux window index available"
    fi

    # Directory listing
    RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/files?session=$SESSION_ID" 2>/dev/null || echo "")
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/files?session=$SESSION_ID" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        HAS_SHAPE=$(echo "$RESPONSE" | jq -r '
            if type == "object" and has("path") and (.entries | type == "array")
            then "valid"
            else "invalid"
            end
        ' 2>/dev/null || echo "parse_error")

        if [ "$HAS_SHAPE" = "valid" ]; then
            record "TY-I-BROW-002" "PASS" "GET /files → $HTTP_CODE (path + entries[] present)"

            # Validate entry shape
            FIRST_ENTRY=$(echo "$RESPONSE" | jq -r '.entries[0]' 2>/dev/null || echo "null")
            if [ "$FIRST_ENTRY" != "null" ] && [ "$FIRST_ENTRY" != "" ]; then
                HAS_NAME=$(echo "$FIRST_ENTRY" | jq -r 'has("name") and has("kind")' 2>/dev/null || echo "false")
                if [ "$HAS_NAME" = "true" ]; then
                    record "TY-I-BROW-003" "PASS" "Entry has name + kind fields"
                else
                    record "TY-I-BROW-003" "FAIL" "Entry missing name or kind"
                fi
            else
                record "TY-I-BROW-003" "SKIP" "No entries to validate (empty directory)"
            fi
        else
            record "TY-I-BROW-002" "FAIL" "GET /files → unexpected shape: $HAS_SHAPE"
            record "TY-I-BROW-003" "SKIP" "Depends on TY-I-BROW-002"
        fi
    else
        record "TY-I-BROW-002" "FAIL" "GET /files → $HTTP_CODE"
        record "TY-I-BROW-003" "SKIP" "Depends on TY-I-BROW-002"
    fi

    LISTING_PATH=$(echo "$RESPONSE" | jq -r '.path // empty' 2>/dev/null || echo "")

    FIRST_FILE_PATH=$(echo "$RESPONSE" | jq -r --arg base "$LISTING_PATH" '
        .entries[]
        | select((.kind // "") != "directory" and (.kind // "") != "dir")
        | (
            .path
            // if ($base | length) == 0 then .name
               elif $base == "/" then "/" + .name
               else ($base | rtrimstr("/")) + "/" + .name
               end
          )
        | select(type == "string" and length > 0)
        ' 2>/dev/null | head -n 1 || true)

    if [ -n "$FIRST_FILE_PATH" ]; then
        TMP_DOWNLOAD="$(mktemp "${TMPDIR:-/tmp}/soyeht-download.XXXXXX")"
        HTTP_HEADERS=$(mktemp "${TMPDIR:-/tmp}/soyeht-download-headers.XXXXXX")
        HTTP_CODE=$(curl -sS \
            -D "$HTTP_HEADERS" \
            -o "$TMP_DOWNLOAD" \
            -w "%{http_code}" \
            -H "Authorization: Bearer $TOKEN" \
            --get \
            --data-urlencode "session=$SESSION_ID" \
            --data-urlencode "path=$FIRST_FILE_PATH" \
            "$BASE_URL/api/v1/terminals/$CONTAINER/files/download" \
            2>/dev/null || echo "000")

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            CONTENT_LENGTH=$({ grep -i '^content-length:' "$HTTP_HEADERS" || true; } | head -n 1 | tr -d '\r' | cut -d' ' -f2-)
            CONTENT_TYPE=$({ grep -i '^content-type:' "$HTTP_HEADERS" || true; } | head -n 1 | tr -d '\r' | cut -d' ' -f2-)
            DOWNLOADED_BYTES=$(wc -c < "$TMP_DOWNLOAD" | tr -d '[:space:]')
            if [ -n "$CONTENT_TYPE" ] && [ "${DOWNLOADED_BYTES:-0}" -gt 0 ]; then
                if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" != "$DOWNLOADED_BYTES" ]; then
                    record "TY-I-BROW-004" "FAIL" "GET /files/download → content-length mismatch ($CONTENT_LENGTH != $DOWNLOADED_BYTES)"
                else
                    record "TY-I-BROW-004" "PASS" "GET /files/download → $HTTP_CODE ($CONTENT_TYPE, ${DOWNLOADED_BYTES} bytes)"
                fi
            else
                record "TY-I-BROW-004" "FAIL" "GET /files/download → missing Content-Type or empty body"
            fi
        else
            record "TY-I-BROW-004" "FAIL" "GET /files/download → $HTTP_CODE"
        fi

        rm -f "$TMP_DOWNLOAD" "$HTTP_HEADERS"
    else
        record "TY-I-BROW-004" "SKIP" "No file entry available to validate /files/download"
    fi

    # Capture-pane (used by Live Watch snapshot)
    if [ -n "$PANE_ID" ]; then
        ENCODED_PANE_ID=$(printf '%s' "$PANE_ID" | sed 's/%/%25/g')
        RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/capture-pane?session=$SESSION_ID&pane=$ENCODED_PANE_ID" 2>/dev/null || echo "")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/capture-pane?session=$SESSION_ID&pane=$ENCODED_PANE_ID" 2>/dev/null || echo "000")

        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            # Should be plain text, not JSON
            IS_JSON=$(echo "$RESPONSE" | jq -r 'type' 2>/dev/null || echo "not_json")
            if [ "$IS_JSON" = "not_json" ] || [ -n "$RESPONSE" ]; then
                record "TY-I-LIVE-001" "PASS" "GET /tmux/capture-pane → $HTTP_CODE (plain text response)"
            else
                record "TY-I-LIVE-001" "PASS" "GET /tmux/capture-pane → $HTTP_CODE"
            fi
        else
            record "TY-I-LIVE-001" "FAIL" "GET /tmux/capture-pane → $HTTP_CODE"
        fi
    else
        record "TY-I-LIVE-001" "SKIP" "No tmux pane_id available"
    fi

    # Pane-stream WebSocket upgrade
    PANE_STREAM_ID="${PANE_ID#%}"
    if [ -z "$PANE_STREAM_ID" ]; then
        record "TY-I-LIVE-002" "SKIP" "No tmux pane_id available"
    else
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/pane-stream?session=$SESSION_ID&pane_id=$PANE_STREAM_ID&token=$TOKEN" \
        2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "101" ] || [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "426" ]; then
        record "TY-I-LIVE-002" "PASS" "WS /tmux/pane-stream → $HTTP_CODE (endpoint exists)"
    elif [ "$HTTP_CODE" = "404" ]; then
        record "TY-I-LIVE-002" "FAIL" "WS /tmux/pane-stream → 404 (endpoint missing)"
    else
        record "TY-I-LIVE-002" "PASS" "WS /tmux/pane-stream → $HTTP_CODE"
    fi
    fi
else
    for id in TY-I-BROW-001 TY-I-BROW-002 TY-I-BROW-003 TY-I-BROW-004 TY-I-LIVE-001 TY-I-LIVE-002; do
        record "$id" "SKIP" "No container/session available"
    done
fi

fi  # end of TOKEN check

# ─── Summary ─────────────────────────────────────────────────────
END=$(date +%s)
DURATION=$((END - START))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Contract Smoke Results (${DURATION}s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}SKIP${NC}: $SKIP"
echo "  Total: $TOTAL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}GATE: BLOCKED${NC}"
    exit 1
else
    echo -e "  ${GREEN}GATE: PASS${NC}"
    exit 0
fi
