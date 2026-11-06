#!/usr/bin/env bash
# Creates the Diagrid project, App IDs, and MCPServer resource.
# Idempotent — safe to re-run. Leaves a deny-all ACL policy; the server
# itself always requires a Keycloak JWT (see README.md's "OIDC / bearer
# middleware"), so nothing works until ./oauth2/setup.sh runs too.
#
# Prereqs: diagrid CLI logged in, docker-compose up -d (Postgres + Keycloak)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " secure-mcp setup — project: $PROJECT"
echo " Baseline: deny-all MCPServer access policy"
echo "============================================"

echo ""
echo ">>> Creating Diagrid project"
diagrid project get "$PROJECT" > /dev/null 2>&1 \
    || diagrid project create "$PROJECT"
diagrid project use "$PROJECT"

# No app-id created for "postgresql-mcp" — the MCPServer resource applied
# below provisions its own backing app-id of the same name.
echo ""
echo ">>> Creating App IDs (3 agents)"
APP_IDS=(
    analyst-mcp-client
    ops-mcp-client
    admin-mcp-client
)
for appid in "${APP_IDS[@]}"; do
    diagrid appid get "$appid" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid appid create "$appid" --project "$PROJECT"
done

echo ""
echo ">>> Applying MCPServer resource (postgresql-mcp → localhost:8001/mcp)"
diagrid apply --project "$PROJECT" -f resources/postgresql-mcp.yaml

echo ""
echo "============================================"
echo " Setup complete"
echo "============================================"
echo ""
echo " Diagrid:   deny-all MCPServer access policy"
echo " OIDC:       postgresql-mcp requires a Keycloak JWT on every call,"
echo "             but nothing attaches one yet, so every call fails (401)."
echo ""
echo " Next:"
echo "   diagrid dev run --project $PROJECT -f dev.yaml"
echo "   diagrid mcpserver access grant ...   # grant the ACL matrix (see README.md)"
echo "   ./oauth2/setup.sh                    # let Diagrid attach its own JWT"
