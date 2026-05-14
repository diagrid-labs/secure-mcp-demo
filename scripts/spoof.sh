#!/usr/bin/env bash
# Three spoof attempts against Catalyst, each demonstrating a different
# layer of defense:
#
#   1. No token         → 401 at the edge, before any policy check
#   2. Forged token     → 401 (token doesn't bind to any app-id)
#   3. Wrong identity   → 403 (token valid → caller IS analyst-agent →
#                              ACL on mcp-db-ddl denies analyst-agent)
#
# Important: all three are rejected at Catalyst's *edge*. The upstream
# MCP servers never see a single one of these requests. The "Server"
# terminal stays silent — that's the defense-in-depth story, not a bug.
#
# The point: you can't escalate by mixing valid creds with another role's
# claim. The token IS the identity.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

DAPR_HTTP_ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.loads(sys.stdin.read()).get('status',{}).get('endpoints',{}).get('http',{}).get('url',''))")

ANALYST_TOKEN=$(diagrid appid get analyst-agent --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.loads(sys.stdin.read()).get('status',{}).get('apiToken',''))")

QUERY_URL="$DAPR_HTTP_ENDPOINT/v1.0/invoke/mcp-db-query/method/mcp"
DDL_URL="$DAPR_HTTP_ENDPOINT/v1.0/invoke/mcp-db-ddl/method/mcp"

# Minimal MCP initialize — we only care about whether auth/policy lets it through
PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"spoof","version":"0"}}}'

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

_call() {
    # Usage: _call <url> [token]
    local url=$1
    local token="${2:-}"
    local body_file
    body_file=$(mktemp)

    local args=(-s -o "$body_file" -w "%{http_code}|%{content_type}"
        -X POST "$url"
        -H "Content-Type: application/json"
        -H "Accept: application/json, text/event-stream")
    if [ -n "$token" ]; then
        args+=(-H "dapr-api-token: $token")
    fi

    local meta
    meta=$(curl "${args[@]}" -d "$PAYLOAD")
    local status="${meta%%|*}"
    local ctype="${meta#*|}"
    local body
    body=$(cat "$body_file")
    rm -f "$body_file"

    # Trim body to a single readable line
    body=$(echo "$body" | tr '\n' ' ' | sed 's/  */ /g' | head -c 200)

    # Color the status code
    local color="$RED"
    [ "$status" = "200" ] && color="$GREEN"

    printf "    status:        ${BOLD}${color}HTTP %s${RESET}\n" "$status"
    printf "    content-type:  ${DIM}%s${RESET}\n" "${ctype:-<empty>}"
    printf "    body:          ${DIM}%s${RESET}\n" "${body:-<empty>}"
}

echo "============================================"
echo " Spoof attempts against Catalyst"
echo " project: $PROJECT"
echo "============================================"

echo ""
echo -e "${BOLD}[1] No token${RESET} — attacker presents no credentials"
echo "    target: mcp-db-query"
echo "    request: POST $QUERY_URL (no dapr-api-token header)"
_call "$QUERY_URL"

echo ""
echo -e "${BOLD}[2] Forged token${RESET} — attacker presents a fake token"
echo "    target: mcp-db-query"
printf "    request: POST + dapr-api-token: ${YELLOW}this-token-was-never-issued-by-catalyst${RESET}\n"
_call "$QUERY_URL" "this-token-was-never-issued-by-catalyst"

echo ""
echo -e "${BOLD}[3] Real analyst token, wrong role${RESET} — auth passes, policy denies"
echo "    target: mcp-db-ddl"
printf "    request: POST + dapr-api-token: ${GREEN}<analyst-agent's real token>${RESET}\n"
echo "    note: token is valid, so the caller IS analyst-agent — and analyst-agent"
echo "          is denied on mcp-db-ddl by the configured ACL."
_call "$DDL_URL" "$ANALYST_TOKEN"

echo ""
echo "============================================"
echo " Expected: 401, 401, 403"
echo ""
echo " Note: the upstream MCP servers (Terminal 1) never received any of"
echo " these requests. Catalyst's edge rejected all three before the"
echo " tunnel was even invoked. That's defense in depth — your servers"
echo " don't have to be hardened against unauthenticated traffic because"
echo " they never see it."
echo "============================================"
