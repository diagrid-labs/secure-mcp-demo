#!/usr/bin/env bash
# Remove the bearer middleware from mcp-db-ddl. Reverts the db-ddl
# Configuration to ACL-only (admin-agent allowed, no JWT requirement).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " oauth2 teardown — removing bearer middleware from mcp-db-ddl"
echo "============================================"

echo ""
echo ">>> Restoring db-ddl Configuration to ACL-only (no appHttpPipeline)"
diagrid configuration update db-ddl --project "$PROJECT" \
    --default-action deny --policy admin-agent:allow

echo ""
echo ">>> Deleting bearer Component"
diagrid component delete bearer --project "$PROJECT" > /dev/null 2>&1 || true

echo ""
echo ">>> Waiting 5s for propagation..."
sleep 5

echo ""
echo "============================================"
echo " OAuth2 enforcement removed from mcp-db-ddl"
echo "============================================"
