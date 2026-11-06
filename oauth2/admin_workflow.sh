#!/usr/bin/env bash
# Admin destructive workflow, end-to-end: insert "Demo Target", show it,
# delete it, show it's gone. Self-resetting — safe to re-run.
#
# Prereqs: admin granted on write + delete tools (diagrid mcpserver access
# grant), and ./scripts/setup.sh + ./oauth2/setup.sh have run.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

_show_employees() {
    docker exec secure-mcp-postgres psql -U postgres demo -c \
        "SELECT id, name, email FROM employees ORDER BY id"
}

echo "============================================"
echo " Admin destructive workflow — end-to-end"
echo "============================================"

echo ""
printf "${BOLD}>>> Fetching admin's Diagrid token...${RESET}\n"
export DAPR_HTTP_ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['endpoints']['http']['url'])")
export DAPR_API_TOKEN=$(diagrid appid get admin-mcp-client --project "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['apiToken'])")
printf "    ${DIM}Diagrid endpoint: $DAPR_HTTP_ENDPOINT${RESET}\n"
printf "    ${DIM}Admin token:       ${DAPR_API_TOKEN:0:10}...${RESET}\n"

# Clear any stray row from a prior run that inserted but failed to delete
# (e.g. a 401) — the unique-email constraint would otherwise block INSERT.
docker exec secure-mcp-postgres psql -U postgres demo -c \
    "DELETE FROM employees WHERE email='demo-target@example.com';" \
    >/dev/null 2>&1 || true

echo ""
printf "${BOLD}>>> Employees BEFORE${RESET}\n"
_show_employees

echo ""
printf "${BOLD}>>> Admin inserts a new employee via postgresql-mcp (insert_employee)...${RESET}\n"
NEW_ID_RAW=$(uv run python oauth2/admin_workflow.py insert)
echo "    $NEW_ID_RAW"
NEW_ID=$(echo "$NEW_ID_RAW" | sed -E 's/^id=([0-9]+).*/\1/')

echo ""
printf "${BOLD}>>> Employees AFTER INSERT (Demo Target visible)${RESET}\n"
_show_employees

echo ""
printf "${BOLD}>>> Admin deletes Demo Target via postgresql-mcp (delete_employee)...${RESET}\n"
printf "    ${DIM}(requires Diagrid ACL allow + Diagrid's own OAuth2 auth)${RESET}\n"
DELETE_RESP=$(uv run python oauth2/admin_workflow.py delete "$NEW_ID")
echo "    $DELETE_RESP"

echo ""
printf "${BOLD}>>> Employees AFTER DELETE (restored to original)${RESET}\n"
_show_employees

echo ""
echo "============================================"
echo " Both operations succeeded. Database state is restored."
echo " - Diagrid ACL allowed admin, and Diagrid's own JWT satisfied"
echo "   postgresql-mcp's verification — both gates passed for each call."
echo "============================================"
