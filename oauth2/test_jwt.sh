#!/usr/bin/env bash
# Sends a single request to mcp-db-ddl with a freshly-fetched Keycloak JWT
# and admin-agent's Catalyst token. Prints full HTTP response including body
# — useful for seeing the middleware's actual rejection reason.

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-mcp-agent}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-mcp-agent-secret}"
PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo ">>> Fetching JWT from Keycloak..."
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=$KEYCLOAK_CLIENT_ID" \
    -d "client_secret=$KEYCLOAK_CLIENT_SECRET" \
    | uv run python -c "import json, sys; print(json.load(sys.stdin)['access_token'])")
echo "    JWT length: ${#TOKEN}"

echo ">>> Reading Catalyst project endpoint + admin-agent token..."
DAPR_ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.load(sys.stdin)['status']['endpoints']['http']['url'])")
ADMIN_TOKEN=$(diagrid appid get admin-agent --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.load(sys.stdin)['status']['apiToken'])")

PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'

echo ">>> Sending request to mcp-db-ddl with Catalyst token + Bearer JWT..."
echo ""
curl -i -X POST "$DAPR_ENDPOINT/v1.0/invoke/mcp-db-ddl/method/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "dapr-api-token: $ADMIN_TOKEN" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$PAYLOAD"
echo ""
