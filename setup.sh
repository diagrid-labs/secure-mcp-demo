#!/usr/bin/env bash
# Creates the Catalyst project, App IDs, and configurations for the
# secure-mcp demo. Idempotent — safe to re-run.
#
# Baseline policy state after this script: **everything denied**.
# Use ./scripts/grant.sh (or ./scripts/up.sh) to open access progressively.
#
# Note: this script needs to update app-ids' --app-config, which is blocked
# while a dev session is active. Run ./reset.sh first to clear sessions.
#
# Prereqs:
#   - diagrid CLI installed and logged in (diagrid login)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " secure-mcp setup — project: $PROJECT"
echo " Baseline: deny-all on every per-op server"
echo "============================================"

# ── 1. Project ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Creating Catalyst project"
diagrid project get "$PROJECT" > /dev/null 2>&1 \
    || diagrid project create "$PROJECT"
diagrid project use "$PROJECT"

# ── 2. App IDs ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Creating App IDs (4 per-op servers + 3 agents)"
APP_IDS=(
    mcp-db-schema
    mcp-db-query
    mcp-db-write
    mcp-db-ddl
    analyst-agent
    ops-agent
    admin-agent
)
for appid in "${APP_IDS[@]}"; do
    diagrid appid get "$appid" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid appid create "$appid" --project "$PROJECT"
done

# ── 3. Configurations ───────────────────────────────────────────────────────
# One config per server op. Default-action: deny, no policies. Grants are
# applied later via ./scripts/grant.sh which mutates these configs in place.
echo ""
echo ">>> Creating deny-all configurations"
_create_config() {
    local name=$1
    diagrid configuration get "$name" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid configuration create "$name" --project "$PROJECT" --default-action deny
}
_create_config db-schema
_create_config db-query
_create_config db-write
_create_config db-ddl

# ── 4. Reset configs to deny-all (re-run idempotency) ───────────────────────
# If a prior run left grants in place, force the configs back to deny-all.
# We can't "clear policies" via the CLI, so we override every agent's entry
# explicitly to :deny.
echo ""
echo ">>> Forcing all configurations back to deny-all baseline"
_deny_all() {
    local config=$1
    diagrid configuration update "$config" --project "$PROJECT" \
        --default-action deny \
        --policy analyst-agent:deny \
        --policy ops-agent:deny \
        --policy admin-agent:deny > /dev/null
}
_deny_all db-schema
_deny_all db-query
_deny_all db-write
_deny_all db-ddl

# ── 5. Apply configs to App IDs ─────────────────────────────────────────────
echo ""
echo ">>> Applying configurations to per-op App IDs"
diagrid appid update mcp-db-schema --project "$PROJECT" --app-config db-schema
diagrid appid update mcp-db-query  --project "$PROJECT" --app-config db-query
diagrid appid update mcp-db-write  --project "$PROJECT" --app-config db-write
diagrid appid update mcp-db-ddl    --project "$PROJECT" --app-config db-ddl

# ── 6. Clean up legacy configs (from earlier iterations) ────────────────────
echo ""
echo ">>> Cleaning up legacy configurations (no-op if not present)"
for legacy in db-schema-allow db-query-allow \
              db-write-restricted db-write-permissive \
              db-ddl-restricted db-ddl-permissive; do
    diagrid configuration delete "$legacy" --project "$PROJECT" > /dev/null 2>&1 || true
done

echo ""
echo "============================================"
echo " Setup complete — every operation is DENIED"
echo "============================================"
echo ""
echo " Next steps:"
echo "   ./scripts/up.sh    # apply the canonical demo matrix"
echo "   ./scripts/grant.sh <op> <agent>...   # progressive grants"
