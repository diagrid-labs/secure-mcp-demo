#!/usr/bin/env bash
# Revoke every agent's access to every tool on mcp-server — back to the
# deny-all baseline. Run before a demo (via the Catalyst UI) to guarantee a
# clean starting state, or between rehearsals.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

AGENTS=(analyst ops admin)
declare -A OP_TOOLS=(
    [query]="query"
    [write]="insert_employee,update_salary"
    [delete]="delete_employee,truncate_table"
)

echo "============================================"
echo " Tearing down all grants — back to deny-all"
echo " project: $PROJECT"
echo "============================================"

for op in query write delete; do
    tools="${OP_TOOLS[$op]}"
    for agent in "${AGENTS[@]}"; do
        echo ">>> Revoking [${agent}-agent] access to tools: ${tools}"
        diagrid mcpserver access revoke mcp-server \
            --caller "${agent}-agent" \
            --allow-tools "$tools" \
            --project "$PROJECT" \
            --wait \
            --approve
    done
done

echo ""
echo "============================================"
echo " Down — every operation now denied"
echo "============================================"
