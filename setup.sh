#!/usr/bin/env bash
# Creates the Catalyst project, App IDs, configurations, AND the OIDC
# bearer middleware on mcp-db-delete. Idempotent — safe to re-run.
#
# Baseline policy state after this script:
#   - Every operation denied for every agent (deny-all on all four configs)
#   - mcp-db-delete additionally requires a valid Keycloak JWT once an agent
#     is granted ACL access — the bearer middleware is permanently wired in
#
# Prereqs:
#   - diagrid CLI installed and logged in (diagrid login)
#   - docker-compose up -d (Postgres + Keycloak)
#   - ngrok exposing Keycloak; KC_HOSTNAME_URL set + Keycloak restarted
#   - KEYCLOAK_PUBLIC_URL exported with the ngrok https URL
#
# Note: this script needs to update app-ids' --app-config, which is blocked
# while a dev session is active. Run ./reset.sh first to clear sessions.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

: "${KEYCLOAK_PUBLIC_URL:?ERROR: KEYCLOAK_PUBLIC_URL must be set — the URL Catalyst can use to reach Keycloak (typically your ngrok https URL)}"
export KEYCLOAK_PUBLIC_URL
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-secure-mcp}"
export KEYCLOAK_AUDIENCE="${KEYCLOAK_AUDIENCE:-https://secure-mcp-demo/}"

echo "============================================"
echo " secure-mcp setup — project: $PROJECT"
echo " Baseline: deny-all on every per-op server"
echo " OIDC: bearer middleware on mcp-db-delete"
echo "============================================"
echo " KEYCLOAK_PUBLIC_URL : $KEYCLOAK_PUBLIC_URL"
echo " KEYCLOAK_REALM      : $KEYCLOAK_REALM"
echo " KEYCLOAK_AUDIENCE   : $KEYCLOAK_AUDIENCE"
echo "============================================"

# ── 1. Project ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Creating Catalyst project"
diagrid project get "$PROJECT" > /dev/null 2>&1 \
    || diagrid project create "$PROJECT"
diagrid project use "$PROJECT"

# ── 2. App IDs ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Creating App IDs (3 per-op servers + 3 agents)"
APP_IDS=(
    mcp-db-query
    mcp-db-write
    mcp-db-delete
    analyst-agent
    ops-agent
    admin-agent
)
for appid in "${APP_IDS[@]}"; do
    diagrid appid get "$appid" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid appid create "$appid" --project "$PROJECT"
done

# ── 3. Configurations ───────────────────────────────────────────────────────
echo ""
echo ">>> Creating deny-all configurations"
_create_config() {
    local name=$1
    diagrid configuration get "$name" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid configuration create "$name" --project "$PROJECT" --default-action deny
}
_create_config db-query
_create_config db-write
_create_config db-delete

# ── 4. Apply configs to App IDs ─────────────────────────────────────────────
echo ""
echo ">>> Applying configurations to per-op App IDs"
diagrid appid update mcp-db-query  --project "$PROJECT" --app-config db-query
diagrid appid update mcp-db-write  --project "$PROJECT" --app-config db-write
diagrid appid update mcp-db-delete    --project "$PROJECT" --app-config db-delete

# ── 5. OIDC layer: bearer Component + middleware wired into db-delete ──────────
echo ""
echo ">>> Applying bearer Component (Keycloak JWT validator, scoped to mcp-db-delete)"
TMP_COMPONENT=$(mktemp /tmp/secure-mcp-bearer-XXXXXX.yaml)
trap 'rm -f "$TMP_COMPONENT"' EXIT
envsubst < oauth2/bearer-component.yaml > "$TMP_COMPONENT"
diagrid apply --project "$PROJECT" -f "$TMP_COMPONENT"

echo ""
echo ">>> Wiring bearer middleware into db-delete Configuration (appHttpPipeline)"
diagrid apply --project "$PROJECT" -f oauth2/config-delete-oauth.yaml

# ── 6. Reset configs to deny-all baseline (preserves appHttpPipeline) ───────
# The config-delete-oauth.yaml we just applied set db-delete to admin-agent:allow.
# Force back to deny-all baseline; the appHttpPipeline (bearer middleware)
# is preserved because `configuration update --policy` doesn't touch it.
echo ""
echo ">>> Forcing all configurations to deny-all baseline"
_deny_all() {
    local config=$1
    diagrid configuration update "$config" --project "$PROJECT" \
        --default-action deny \
        --policy analyst-agent:deny \
        --policy ops-agent:deny \
        --policy admin-agent:deny > /dev/null
}
_deny_all db-query
_deny_all db-write
_deny_all db-delete

# ── 7. Clean up legacy configs (from earlier iterations) ────────────────────
echo ""
echo ">>> Cleaning up legacy configurations (no-op if not present)"
for legacy in db-schema-allow db-query-allow \
              db-write-restricted db-write-permissive \
              db-ddl-restricted db-ddl-permissive; do
    diagrid configuration delete "$legacy" --project "$PROJECT" > /dev/null 2>&1 || true
done

echo ""
echo "============================================"
echo " Setup complete"
echo "============================================"
echo ""
echo " Catalyst:   deny-all on every per-op server"
echo " OIDC:       bearer middleware on mcp-db-delete (always-on)"
echo ""
echo " Next:"
echo "   diagrid dev run --project $PROJECT -f dev.yaml"
echo "   ./scripts/up.sh    or    progressive ./scripts/grant.sh"
