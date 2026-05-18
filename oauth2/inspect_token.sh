#!/usr/bin/env bash
# Fetches a fresh JWT from Keycloak via client_credentials and prints
# the decoded header + claims (especially `kid`, `iss`, `aud`). Useful
# for debugging the bearer middleware.

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-mcp-agent}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-mcp-agent-secret}"

TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=$KEYCLOAK_CLIENT_ID" \
    -d "client_secret=$KEYCLOAK_CLIENT_SECRET" \
    | uv run python -c "import json, sys; print(json.load(sys.stdin)['access_token'])")

echo "=== Access token HEADER ==="
uv run python <<PY
import base64, json
t = "$TOKEN"
h = t.split('.')[0]
h += '=' * (-len(h) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(h)), indent=2))
PY

echo ""
echo "=== Access token CLAIMS (payload) ==="
uv run python <<PY
import base64, json
t = "$TOKEN"
p = t.split('.')[1]
p += '=' * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))
PY

echo ""
echo "=== JWKS at issuer (keys currently published by Keycloak) ==="
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-$KEYCLOAK_URL}"
curl -s "$KEYCLOAK_PUBLIC_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/certs" | \
    uv run python -c "import json, sys; d=json.load(sys.stdin); print('  kids:', [k.get('kid') for k in d.get('keys', [])])"
