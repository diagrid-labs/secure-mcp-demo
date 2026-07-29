#!/usr/bin/env bash
# Enables Catalyst-NATIVE OAuth 2.0 client-credentials auth on the MCPServer
# resource itself, per:
#   https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials
#
# This is THE demo's step-up mechanic. `./setup.sh` (repo root) already made
# every call to mcp-server require a valid Keycloak-issued JWT — see the
# bearer middleware it applies. Before this script runs, nothing can attach
# that JWT, so every call fails (401), regardless of the MCPServer access
# policy. Running this script configures Catalyst itself to fetch and
# attach its own JWT (via client_credentials, using its own dedicated
# Keycloak client "catalyst-proxy" — distinct from any agent identity) on
# every call it forwards. Only after this runs do calls succeed (still
# gated by the per-tool MCPServer access policy on top).
#
# Prereqs:
#   - Catalyst project + MCPServer resource + bearer middleware exist (./setup.sh)
#   - Keycloak running and reachable at KEYCLOAK_PUBLIC_URL, with the
#     "catalyst-proxy" client imported (see keycloak/realm-export.json)
#
# Environment:
#   KEYCLOAK_PUBLIC_URL          — URL Catalyst's control plane can reach
#                                  Keycloak at. Defaults to http://localhost:8080
#                                  (only works if Catalyst runs locally; most
#                                  setups need a public URL, e.g. an ngrok
#                                  tunnel for local dev, or the ingress FQDN
#                                  + /keycloak for the k8s deployment).
#   KEYCLOAK_REALM                — defaults to "secure-mcp"
#   KEYCLOAK_AUDIENCE             — defaults to "https://secure-mcp-demo/"
#   CATALYST_PROXY_CLIENT_SECRET  — defaults to "catalyst-proxy-secret"
#                                   (matches keycloak/realm-export.json)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

export KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-http://localhost:8080}"
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
export KEYCLOAK_AUDIENCE="${KEYCLOAK_AUDIENCE:-https://secure-mcp-demo/}"
export CATALYST_PROXY_CLIENT_SECRET="${CATALYST_PROXY_CLIENT_SECRET:-catalyst-proxy-secret}"

echo "============================================"
echo " Catalyst-native OAuth2 client-credentials auth"
echo " (Catalyst -> mcp-server)"
echo "============================================"
echo " KEYCLOAK_PUBLIC_URL : $KEYCLOAK_PUBLIC_URL"
echo " KEYCLOAK_REALM      : $KEYCLOAK_REALM"
echo " KEYCLOAK_AUDIENCE   : $KEYCLOAK_AUDIENCE"
echo " clientID            : catalyst-proxy"
echo "============================================"

if [[ "$KEYCLOAK_PUBLIC_URL" == *"localhost"* ]]; then
    echo ""
    echo " ⚠️  KEYCLOAK_PUBLIC_URL is localhost. Catalyst's control plane runs"
    echo "     in the cloud and can't reach a bare localhost URL — token"
    echo "     fetches will fail unless Keycloak is genuinely reachable there"
    echo "     (e.g. an ngrok tunnel, or the k8s deployment's public ingress"
    echo "     FQDN + /keycloak)."
fi

CURRENT_URL=$(diagrid mcpserver get mcp-server --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.load(sys.stdin)['spec']['endpoint']['streamableHTTP']['url'])")
echo ""
echo ">>> Current endpoint URL (preserved): $CURRENT_URL"

TMP=$(mktemp /tmp/secure-mcp-catalyst-oauth-XXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
apiVersion: dapr.io/v1alpha1
kind: MCPServer
metadata:
  name: mcp-server
spec:
  endpoint:
    streamableHTTP:
      url: ${CURRENT_URL}
      auth:
        oauth2:
          issuer: ${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token
          audience: ${KEYCLOAK_AUDIENCE}
          clientID: catalyst-proxy
          scopes: []
          clientSecret: ${CATALYST_PROXY_CLIENT_SECRET}
EOF

echo ""
echo ">>> Applying MCPServer resource with Catalyst-native OAuth2 auth"
diagrid apply --project "$PROJECT" -f "$TMP"

echo ""
echo "============================================"
echo " Catalyst will now fetch + attach its own OAuth2 token on every"
echo " call it forwards to mcp-server. Calls now succeed, gated only by"
echo " the MCPServer access policy (./scripts/up.sh / grant.sh)."
echo ""
echo " Verify:"
echo "   diagrid mcpserver get mcp-server --project $PROJECT -o json | jq '.spec.endpoint.streamableHTTP.auth'"
echo ""
echo " To revert: ./oauth2/teardown.sh"
echo "============================================"
