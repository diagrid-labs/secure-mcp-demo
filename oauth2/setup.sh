#!/usr/bin/env bash
# Layer Keycloak/OIDC bearer enforcement on top of mcp-db-ddl. After this
# runs, every call to mcp-db-ddl must present a valid JWT issued by the
# Keycloak realm.
#
# Prereqs:
#   - Catalyst project + app-ids exist (from running ./setup.sh)
#   - Keycloak running locally (docker-compose up -d)
#   - admin-agent already granted on mcp-db-ddl (e.g. ./scripts/up.sh)
#
# Environment:
#   KEYCLOAK_PUBLIC_URL  — URL Catalyst's cloud-side middleware can reach
#                          Keycloak at (e.g. https://abc-123.ngrok-free.app).
#                          Defaults to http://localhost:8080, which only
#                          works if the middleware executes locally — most
#                          Catalyst dev-tunnel setups need a public URL.
#   KEYCLOAK_REALM       — defaults to "secure-mcp"
#   KEYCLOAK_AUDIENCE    — defaults to "https://secure-mcp-demo/"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

export KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://localhost:8080}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
export KEYCLOAK_AUDIENCE="${KEYCLOAK_AUDIENCE:-https://secure-mcp-demo/}"

echo "============================================"
echo " oauth2 setup — adding bearer middleware to mcp-db-ddl"
echo "============================================"
echo " KEYCLOAK_PUBLIC_URL : $KEYCLOAK_PUBLIC_URL"
echo " KEYCLOAK_REALM      : $KEYCLOAK_REALM"
echo " KEYCLOAK_AUDIENCE   : $KEYCLOAK_AUDIENCE"
echo "============================================"

if [[ "$KEYCLOAK_PUBLIC_URL" == *"localhost"* ]]; then
    echo ""
    echo " ⚠️  KEYCLOAK_PUBLIC_URL is localhost. If Catalyst's middleware"
    echo "     runs at the cloud edge it won't be able to reach Keycloak"
    echo "     here and JWT validation will silently fail open."
    echo "     If you see admin still able to ddl without a JWT, run:"
    echo "         ngrok http 8080"
    echo "     and re-run this script with KEYCLOAK_PUBLIC_URL=<ngrok https URL>"
fi

echo ""
echo ">>> Applying bearer Component (scoped to mcp-db-ddl)"
TMP_COMPONENT=$(mktemp /tmp/secure-mcp-bearer-XXXXXX.yaml)
trap 'rm -f "$TMP_COMPONENT"' EXIT
envsubst < oauth2/bearer-component.yaml > "$TMP_COMPONENT"
diagrid apply --project "$PROJECT" -f "$TMP_COMPONENT"

echo ""
echo ">>> Updating db-ddl Configuration to include the bearer middleware"
echo "    (this preserves the existing ACL — admin-agent stays allowed)"
diagrid apply --project "$PROJECT" -f oauth2/config-ddl-oauth.yaml

echo ""
echo ">>> Waiting 5s for propagation..."
sleep 5

echo ""
echo "============================================"
echo " OAuth2 enforcement is now active on mcp-db-ddl"
echo "============================================"
echo ""
echo " Calls to mcp-db-ddl now require BOTH:"
echo "   - a valid Catalyst dapr-api-token (existing)"
echo "   - a valid Bearer JWT from Keycloak (new)"
echo ""
echo " To make the agent fetch and present a JWT:"
echo "   export KEYCLOAK_URL=http://localhost:8080"
echo "   export KEYCLOAK_REALM=$KEYCLOAK_REALM"
echo "   export KEYCLOAK_CLIENT_ID=mcp-agent"
echo "   export KEYCLOAK_CLIENT_SECRET=mcp-agent-secret"
echo "   export KEYCLOAK_AUDIENCE=$KEYCLOAK_AUDIENCE"
echo ""
echo " (KEYCLOAK_URL for the agent is always localhost — the agent runs"
echo "  on your machine. KEYCLOAK_PUBLIC_URL is for Catalyst to reach in)"
echo ""
echo " To revert: ./oauth2/teardown.sh"
