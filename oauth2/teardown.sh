#!/usr/bin/env bash
# Removes Catalyst-native OAuth2 auth from the MCPServer resource (see
# ./oauth2/setup.sh), reverting to a bare endpoint URL with no Catalyst-side
# authentication to mcp-server. Since the bearer middleware applied by the
# repo-root ./setup.sh always requires a valid JWT, this puts every call
# back into deny — the demo's "secure by default" baseline.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " Removing Catalyst-native OAuth2 auth from mcp-server"
echo "============================================"

CURRENT_URL=$(diagrid mcpserver get mcp-server --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.load(sys.stdin)['spec']['endpoint']['streamableHTTP']['url'])")

TMP=$(mktemp /tmp/secure-mcp-catalyst-oauth-teardown-XXXXXX.yaml)
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
EOF

diagrid apply --project "$PROJECT" -f "$TMP"

echo ""
echo "============================================"
echo " Catalyst -> mcp-server auth removed. Every call now fails (401) —"
echo " the bearer middleware still requires a JWT, and nothing attaches"
echo " one anymore. Run ./oauth2/setup.sh to re-enable."
echo "============================================"
