#!/usr/bin/env bash
# Creates the Catalyst project, App IDs, and configurations for the
# secure-mcp demo. Idempotent — safe to re-run.
#
# Prereqs:
#   - diagrid CLI installed and logged in (diagrid login)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

echo "============================================"
echo " secure-mcp setup — project: $PROJECT"
echo "============================================"

# ── 1. Project ──────────────────────────────────────────────────────────────
echo ""
echo ">>> Creating Catalyst project"
diagrid project get "$PROJECT" > /dev/null 2>&1 \
    || diagrid project create "$PROJECT"
diagrid project use "$PROJECT"

# ── 2. App IDs ──────────────────────────────────────────────────────────────
# Per-op MCP server app-ids + per-role agent app-ids. The "one app-id per
# operation" pattern is what lets us govern each tool independently.
echo ""
echo ">>> Creating App IDs"
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
# Two configurations per per-op server: the "policy" we want for the demo,
# plus a "permissive" sibling we can hot-swap to for live-grant moments.
echo ""
echo ">>> Creating access control configurations"

_create_config() {
    local name=$1; shift
    diagrid configuration get "$name" --project "$PROJECT" > /dev/null 2>&1 \
        || diagrid configuration create "$name" --project "$PROJECT" "$@"
}

# schema + query: all three agents allowed
_create_config db-schema-allow --default-action allow
_create_config db-query-allow  --default-action allow

# write: ops and admin allowed, analyst denied
_create_config db-write-restricted --default-action allow --policy analyst-agent:deny
_create_config db-write-permissive  --default-action allow  # phase-3 swap target

# ddl: admin only
_create_config db-ddl-restricted --default-action allow \
    --policy analyst-agent:deny --policy ops-agent:deny
_create_config db-ddl-permissive --default-action allow  # phase-3 swap target

# ── 4. Apply initial policies ───────────────────────────────────────────────
echo ""
echo ">>> Applying initial configurations to App IDs"
diagrid appid update mcp-db-schema --project "$PROJECT" --app-config db-schema-allow
diagrid appid update mcp-db-query  --project "$PROJECT" --app-config db-query-allow
diagrid appid update mcp-db-write  --project "$PROJECT" --app-config db-write-restricted
diagrid appid update mcp-db-ddl    --project "$PROJECT" --app-config db-ddl-restricted

echo ""
echo "============================================"
echo " Setup complete"
echo "============================================"
echo ""
echo " Policy matrix:"
echo "   analyst-agent  schema:✓  query:✓  write:✗  ddl:✗"
echo "   ops-agent      schema:✓  query:✓  write:✓  ddl:✗"
echo "   admin-agent    schema:✓  query:✓  write:✓  ddl:✓"
