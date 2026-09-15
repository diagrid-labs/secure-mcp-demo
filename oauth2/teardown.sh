#!/usr/bin/env bash
# Reverts ./oauth2/setup.sh: strips Catalyst's OAuth2 auth from the
# MCPServer resource. postgresql-mcp still requires a JWT on every call,
# so with nothing left to supply one, every call goes back to 401.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " Removing Catalyst-native OAuth2 auth from postgresql-mcp"
echo "============================================"

CURRENT_URL=$(diagrid mcpserver get postgresql-mcp --project "$PROJECT" -o json | \
    uv run python -c "import json,sys; print(json.load(sys.stdin)['spec']['endpoint']['streamableHTTP']['url'])")

TMP=$(mktemp /tmp/secure-mcp-catalyst-oauth-teardown-XXXXXX.yaml)
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
EOF

diagrid apply --project "$PROJECT" -f "$TMP"

echo ""
echo "============================================"
echo " Catalyst -> postgresql-mcp auth removed. Every call now fails (401) —"
echo " nothing attaches a JWT anymore. Run ./oauth2/setup.sh to re-enable."
echo "============================================"
