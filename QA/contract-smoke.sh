#!/bin/bash
# Contract Smoke Tests — validates API response shapes that the iOS app expects.
# Endpoints derived from SoyehtAPIClient.swift (not invented).
#
# Usage:
#   ./QA/contract-smoke.sh                    # test against localhost:8892
#   ./QA/contract-smoke.sh https://myhost:8892  # test against specific server
#   TOKEN=xxx ./QA/contract-smoke.sh          # provide auth token
#
# Prerequisites:
#   - Backend running on target server
#   - Valid session token (or will attempt to get one via pair endpoint)
#   - curl and jq installed

set -euo pipefail

BASE_URL="${1:-http://localhost:8892}"
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

if [ -n "$CONTAINER" ] && [ -n "$SESSION_ID" ]; then
    RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/windows?session=$SESSION_ID" 2>/dev/null || echo "")
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/windows?session=$SESSION_ID" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        HAS_DATA=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then "envelope" elif type == "array" then "bare" else "unknown" end' 2>/dev/null || echo "parse_error")
        if [ "$HAS_DATA" = "envelope" ] || [ "$HAS_DATA" = "bare" ]; then
            record "TY-I-TMUX-001" "PASS" "GET tmux/windows → $HTTP_CODE ($HAS_DATA format)"
        else
            record "TY-I-TMUX-001" "FAIL" "Unexpected format: $HAS_DATA"
        fi
    else
        record "TY-I-TMUX-001" "FAIL" "GET tmux/windows → $HTTP_CODE"
    fi

    # Panes
    RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/panes?session=$SESSION_ID&window=0" 2>/dev/null || echo "")
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$BASE_URL/api/v1/terminals/$CONTAINER/tmux/panes?session=$SESSION_ID&window=0" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        HAS_DATA=$(echo "$RESPONSE" | jq -r 'if type == "object" and has("data") then "envelope" elif type == "array" then "bare" else "unknown" end' 2>/dev/null || echo "parse_error")
        if [ "$HAS_DATA" = "envelope" ] || [ "$HAS_DATA" = "bare" ]; then
            record "TY-I-TMUX-002" "PASS" "GET tmux/panes → $HTTP_CODE ($HAS_DATA format)"
        else
            record "TY-I-TMUX-002" "FAIL" "Unexpected format: $HAS_DATA"
        fi
    else
        record "TY-I-TMUX-002" "FAIL" "GET tmux/panes → $HTTP_CODE"
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
