#!/usr/bin/env bash
# THE demo's step-up mechanic. postgresql-mcp always requires a Keycloak
# JWT, but nothing supplies one until this configures Diagrid's own
# OAuth2 client-credentials (client "catalyst-proxy") on the MCPServer
# resource, so Diagrid fetches + attaches its own JWT on every call it
# forwards. Per https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials.
#
# Prereqs: ./scripts/setup.sh has run; Keycloak reachable at
# KEYCLOAK_PUBLIC_URL with the "catalyst-proxy" client imported
# (see keycloak/realm-export.json).
#
# Env vars (all optional):
#   KEYCLOAK_PUBLIC_URL — URL Diagrid's control plane can reach Keycloak
#                         at (default http://localhost:8080, only works if
#                         Diagrid runs locally — most setups need a public
#                         URL: an ngrok tunnel, or the k8s ingress FQDN +
#                         /keycloak)
#   KEYCLOAK_REALM                — default "secure-mcp"
#   KEYCLOAK_AUDIENCE             — default "https://secure-mcp-demo/"
#   CATALYST_PROXY_CLIENT_SECRET  — default "catalyst-proxy-secret"
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
echo " Diagrid-native OAuth2 client-credentials auth"
echo " (Diagrid -> postgresql-mcp)"
echo "============================================"
echo " KEYCLOAK_PUBLIC_URL : $KEYCLOAK_PUBLIC_URL"
echo " KEYCLOAK_REALM      : $KEYCLOAK_REALM"
echo " KEYCLOAK_AUDIENCE   : $KEYCLOAK_AUDIENCE"
echo " clientID            : catalyst-proxy"
echo "============================================"

if [[ "$KEYCLOAK_PUBLIC_URL" == *"localhost"* ]]; then
    echo ""
    echo " ⚠️  KEYCLOAK_PUBLIC_URL is localhost. Diagrid's control plane runs"
    echo "     in the cloud and can't reach a bare localhost URL — token"
    echo "     fetches will fail unless Keycloak is genuinely reachable there"
    echo "     (e.g. an ngrok tunnel, or the k8s deployment's public ingress"
    echo "     FQDN + /keycloak)."
fi

CURRENT_URL=$(diagrid mcpserver get postgresql-mcp --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.load(sys.stdin)['spec']['endpoint']['streamableHTTP']['url'])")
echo ""
echo ">>> Current endpoint URL (preserved): $CURRENT_URL"

TMP=$(mktemp /tmp/secure-mcp-catalyst-oauth-XXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
apiVersion: dapr.io/v1alpha1
kind: MCPServer
metadata:
  name: postgresql-mcp
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
echo ">>> Applying MCPServer resource with Diagrid-native OAuth2 auth"
diagrid apply --project "$PROJECT" -f "$TMP"

echo ""
echo "============================================"
echo " Diagrid will now fetch + attach its own OAuth2 token on every"
echo " call it forwards to postgresql-mcp. Calls now succeed, gated only by"
echo " the MCPServer access policy (diagrid mcpserver access grant ...)."
echo ""
echo " Verify:"
echo "   diagrid mcpserver get postgresql-mcp --project $PROJECT -o json | jq '.spec.endpoint.streamableHTTP.auth'"
echo ""
echo " To revert: ./oauth2/teardown.sh"
echo "============================================"
