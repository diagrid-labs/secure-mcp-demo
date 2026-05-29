#!/usr/bin/env bash
# Ping each per-op MCP server every 30s so the diagrid dev tunnels don't
# go idle during a long demo. Run in a 3rd terminal. Ctrl+C to stop.
#
# Prereqs: ./scripts/up.sh applied (admin allowed everywhere) and the
# KEYCLOAK_* agent vars exported (needed to mint a JWT for mcp-db-delete).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

: "${KEYCLOAK_URL:?ERROR: export the KEYCLOAK_* vars first (see DEMO.md pre-demo step 5)}"
: "${KEYCLOAK_REALM:?ERROR: KEYCLOAK_REALM must be set}"
: "${KEYCLOAK_CLIENT_ID:?ERROR: KEYCLOAK_CLIENT_ID must be set}"
: "${KEYCLOAK_CLIENT_SECRET:?ERROR: KEYCLOAK_CLIENT_SECRET must be set}"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"
ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['endpoints']['http']['url'])")
TOKEN=$(diagrid appid get admin-agent --project "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['apiToken'])")

PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"keepalive","version":"0"}}}'

echo "keepalive: pinging 4 per-op tunnels every 10s. Ctrl+C to stop."
while true; do
    JWT=$(curl -s -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
        -d "grant_type=client_credentials" -d "client_id=$KEYCLOAK_CLIENT_ID" \
        -d "client_secret=$KEYCLOAK_CLIENT_SECRET" | \
        uv run python -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
    for app in mcp-db-query mcp-db-write mcp-db-delete; do
        code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT/v1.0/invoke/$app/method/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -H "dapr-api-token: $TOKEN" \
            -H "Authorization: Bearer $JWT" \
            -d "$PAYLOAD" || echo "ERR")
        case "$code" in
            200) ;;
            *) echo "$(date +%H:%M:%S) keepalive: $app -> HTTP $code" >&2 ;;
        esac
    done
    sleep 10
done
