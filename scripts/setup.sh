#!/usr/bin/env bash
# Creates the Catalyst project, App IDs, and MCPServer resource. Idempotent
# — safe to re-run. Baseline policy state after this script:
#   - MCPServer access policy: deny-all (default for new MCPServer resources)
#   - mcp-server itself always requires a valid Keycloak-issued bearer JWT
#     on every call (verified in application code — see servers/mcp_server.py
#     and README.md's "OIDC / bearer middleware"). Nothing supplies that JWT
#     until ./oauth2/setup.sh configures Catalyst's own OAuth2
#     client-credentials on the MCPServer resource — that's the demo's
#     step-up beat, see DEMO.md.
#
# Prereqs:
#   - diagrid CLI installed and logged in (diagrid login)
#   - docker-compose up -d (Postgres + Keycloak)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " secure-mcp setup — project: $PROJECT"
echo " Baseline: deny-all MCPServer access policy"
echo "============================================"

# ── 1. Project ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Creating Catalyst project"
diagrid project get "$PROJECT" > /dev/null 2>&1 \
    || diagrid project create "$PROJECT"
diagrid project use "$PROJECT"

# ── 2. App IDs ──────────────────────────────────────────────────────────────
# Note: no app-id is created for "mcp-server" here — the MCPServer resource
# applied below (step 3) provisions its own backing app-id of the same name.
# Creating one explicitly first causes step 3 to fail with "an App ID with
# the same name already exists".
echo ""
echo ">>> Creating App IDs (3 agents)"
APP_IDS=(
    analyst-agent
    ops-agent
    admin-agent
)
for appid in "${APP_IDS[@]}"; do
    diagrid appid get "$appid" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid appid create "$appid" --project "$PROJECT"
done

# ── 3. MCPServer resource ────────────────────────────────────────────────────
echo ""
echo ">>> Applying MCPServer resource (mcp-server → localhost:8001/mcp)"
diagrid apply --project "$PROJECT" -f resources/mcp-server.yaml

# ── 4. Clean up legacy resources from the 3-server setup ────────────────────
echo ""
echo ">>> Cleaning up legacy app-ids and configurations (no-op if not present)"
for legacy_appid in mcp-db-query mcp-db-write mcp-db-delete; do
    diagrid appid delete "$legacy_appid" --project "$PROJECT" > /dev/null 2>&1 || true
done
for legacy_config in db-query db-write db-delete \
                     db-schema-allow db-query-allow \
                     db-write-restricted db-write-permissive \
                     db-ddl-restricted db-ddl-permissive; do
    diagrid configuration delete "$legacy_config" --project "$PROJECT" > /dev/null 2>&1 || true
done

echo ""
echo "============================================"
echo " Setup complete"
echo "============================================"
echo ""
echo " Catalyst:   deny-all MCPServer access policy"
echo " OIDC:       mcp-server itself requires a Keycloak JWT on every call,"
echo "             but nothing attaches one yet, so every call fails (401)."
echo ""
echo " Next:"
echo "   diagrid dev run --project $PROJECT -f dev.yaml"
echo "   ./scripts/up.sh                 # grant the canonical ACL matrix"
echo "   ./oauth2/setup.sh               # let Catalyst attach its own JWT — calls start working"
