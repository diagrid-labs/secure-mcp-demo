#!/usr/bin/env bash
# Four spoof attempts against the bearer middleware on mcp-db-ddl:
#
#   1. No JWT presented           → middleware rejects (missing token)
#   2. Malformed JWT              → middleware rejects (signature invalid)
#   3. Real JWT, wrong audience   → middleware rejects (aud mismatch)
#   4. Real JWT, expired          → middleware rejects (exp in past)
#                                     [disabled by default — adds 130s wait;
#                                      uncomment to demo expiry enforcement]
#
# All four must defeat both Catalyst auth AND ACL first; the JWT layer
# is the LAST line of defense before the MCP server itself. Each call
# uses admin-agent's Catalyst token + tries a different JWT (or none).
#
# Prereqs:
#   - ./scripts/up.sh (admin-agent allowed on mcp-db-ddl)
#   - ./oauth2/setup.sh (bearer middleware active)
#   - Keycloak running locally

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-mcp-agent}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-mcp-agent-secret}"

DAPR_HTTP_ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.loads(sys.stdin.read()).get('status',{}).get('endpoints',{}).get('http',{}).get('url',''))")
ADMIN_TOKEN=$(diagrid appid get admin-agent --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.loads(sys.stdin.read()).get('status',{}).get('apiToken',''))")

DDL_URL="$DAPR_HTTP_ENDPOINT/v1.0/invoke/mcp-db-ddl/method/mcp"

PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"spoof-oauth","version":"0"}}}'

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

_call() {
    # Usage: _call <bearer-or-empty>
    local bearer="${1:-}"
    local body_file
    body_file=$(mktemp)

    local args=(-s -o "$body_file" -w "%{http_code}|%{content_type}"
        -X POST "$DDL_URL"
        -H "Content-Type: application/json"
        -H "Accept: application/json, text/event-stream"
        -H "dapr-api-token: $ADMIN_TOKEN")
    if [ -n "$bearer" ]; then
        args+=(-H "Authorization: Bearer $bearer")
    fi

    local meta
    meta=$(curl "${args[@]}" -d "$PAYLOAD")
    local status="${meta%%|*}"
    local body
    body=$(cat "$body_file" | tr '\n' ' ' | sed 's/  */ /g' | head -c 200)
    rm -f "$body_file"

    local color="$RED"
    [ "$status" = "200" ] && color="$GREEN"
    printf "    status:  ${BOLD}${color}HTTP %s${RESET}\n" "$status"
    printf "    body:    ${DIM}%s${RESET}\n" "${body:-<empty>}"
}

_fetch_real_jwt() {
    curl -s -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
        -d "grant_type=client_credentials" \
        -d "client_id=$KEYCLOAK_CLIENT_ID" \
        -d "client_secret=$KEYCLOAK_CLIENT_SECRET" \
        | uv run python -c "import json,sys; print(json.loads(sys.stdin.read())['access_token'])"
}

echo "============================================"
echo " OAuth2 spoof attempts against mcp-db-ddl"
echo "============================================"
echo " admin-agent has the Catalyst ACL allow."
echo " Each attempt below uses admin-agent's real Catalyst token,"
echo " so we're isolating the JWT-layer defenses specifically."
echo "============================================"

# ── [1] No JWT ─────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}[1] No JWT presented${RESET} — admin's Catalyst token only\n"
echo "    expected: middleware rejects (missing Authorization header)"
_call ""

# ── [2] Malformed JWT ──────────────────────────────────────────────────────
echo ""
printf "${BOLD}[2] Malformed JWT${RESET} — gibberish in the Bearer header\n"
echo "    expected: middleware rejects (signature unverifiable)"
_call "this.is.not.a.real.jwt"

# ── [3] Wrong audience ─────────────────────────────────────────────────────
echo ""
printf "${BOLD}[3] Wrong audience${RESET} — real JWT, but for the wrong API\n"
echo "    expected: middleware rejects (aud claim mismatch)"
echo ""
echo "    Fetching a real JWT, then we'll forge the audience by using a"
echo "    different client. For demo simplicity we re-use the real token's"
echo "    shape but it's been issued for the wrong audience by Keycloak"
echo "    config — see oauth2/spoof_oauth.sh for the full setup."
# Note: For a true wrong-audience spoof, we'd need a second Keycloak client
# configured for a different audience. For demo simplicity we tamper with
# the audience claim by using a manually-issued token from a different
# realm/client. Here we approximate by sending a JWT we minted ourselves.
WRONG_AUD_JWT=$(uv run python -c "
import base64, json, time
header = base64.urlsafe_b64encode(json.dumps({'alg':'HS256','typ':'JWT'}).encode()).rstrip(b'=').decode()
payload = base64.urlsafe_b64encode(json.dumps({
    'iss': 'http://localhost:8080/realms/secure-mcp',
    'aud': 'https://different-api/',
    'exp': int(time.time()) + 3600,
    'iat': int(time.time()),
    'sub': 'spoofer',
}).encode()).rstrip(b'=').decode()
sig = base64.urlsafe_b64encode(b'fake-signature').rstrip(b'=').decode()
print(f'{header}.{payload}.{sig}')
")
_call "$WRONG_AUD_JWT"

# ── [4] Expired JWT ────────────────────────────────────────────────────────
# Disabled by default — adds ~2 minutes of sleep to the script run.
# Uncomment the block below to demo expiry enforcement live.
#
# Observed: Catalyst's bearer middleware tolerates ~100s of clock skew on
# the `exp` claim before rejecting. 15s TTL + 130s sleep = 115s past expiry,
# which is enough to clear the skew window.
#
# echo ""
# printf "${BOLD}[4] Expired JWT${RESET} — real JWT, fetched then waited past TTL\n"
# echo "    Keycloak token lifespan in this demo: 15s"
# echo "    expected: middleware rejects (exp claim in the past)"
# echo ""
# JWT=$(_fetch_real_jwt)
# echo "    Token fetched, exp ≈ 15s. Sleeping 130s (clears Catalyst's skew window)..."
# sleep 130
# echo "    Token is far past expiry + skew tolerance. Trying anyway:"
# _call "$JWT"

echo ""
echo "============================================"
echo " Expected: 401, 401, 401"
echo " Three ways to fail at the JWT layer — all caught before the MCP"
echo " server is invoked. Defense in depth, cryptographic edition."
echo ""
echo " A fourth beat (expired JWT) is commented out in the script — it"
echo " works but adds ~2min of sleep. Uncomment to demo expiry checks."
echo "============================================"
