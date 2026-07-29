#!/usr/bin/env bash
# Demonstrates an admin destructive workflow end-to-end with visible state:
#   1. Show DB state (5 rows)
#   2. Admin inserts "Demo Target" via mcp-server (insert_employee tool)
#   3. Show DB state (6 rows — Demo Target visible)
#   4. Admin deletes "Demo Target" via mcp-server (delete_employee tool)
#   5. Show DB state (5 rows — restored)
#
# Both operations go through the single MCPServer proxy and require admin's
# Catalyst token. mcp-server also requires a valid Keycloak JWT on every
# call — checked in its own application code (see ../servers/mcp_server.py)
# — but that JWT is Catalyst's own, attached automatically via OAuth2
# client-credentials configured on the MCPServer resource (./setup.sh).
# This script never touches Keycloak directly. Self-resetting — safe to
# re-run.
#
# Prereqs:
#   - ./scripts/up.sh (admin granted on write + delete tools)
#   - ./setup.sh && ./oauth2/setup.sh (bearer middleware + Catalyst OAuth2 auth active)

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
printf "${BOLD}>>> Fetching admin's Catalyst token...${RESET}\n"
export DAPR_HTTP_ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['endpoints']['http']['url'])")
export DAPR_API_TOKEN=$(diagrid appid get admin-agent --project "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['apiToken'])")
printf "    ${DIM}Catalyst endpoint: $DAPR_HTTP_ENDPOINT${RESET}\n"
printf "    ${DIM}Admin token:       ${DAPR_API_TOKEN:0:10}...${RESET}\n"

# If a prior run inserted Demo Target but couldn't delete it (e.g. Catalyst's
# OAuth2 auth wasn't configured on the MCPServer resource yet, so the delete
# call 401'd), the unique-email constraint blocks this run's INSERT. Clear
# any stray row so BEFORE always shows the canonical 5-row state.
docker exec secure-mcp-postgres psql -U postgres demo -c \
    "DELETE FROM employees WHERE email='demo-target@example.com';" \
    >/dev/null 2>&1 || true

echo ""
printf "${BOLD}>>> Employees BEFORE${RESET}\n"
_show_employees

echo ""
printf "${BOLD}>>> Admin inserts a new employee via mcp-server (insert_employee)...${RESET}\n"
NEW_ID_RAW=$(uv run python oauth2/admin_workflow.py insert)
echo "    $NEW_ID_RAW"
NEW_ID=$(echo "$NEW_ID_RAW" | sed -E 's/^id=([0-9]+).*/\1/')

echo ""
printf "${BOLD}>>> Employees AFTER INSERT (Demo Target visible)${RESET}\n"
_show_employees

echo ""
printf "${BOLD}>>> Admin deletes Demo Target via mcp-server (delete_employee)...${RESET}\n"
printf "    ${DIM}(requires Catalyst ACL allow + Catalyst's own OAuth2 auth on the MCPServer resource)${RESET}\n"
DELETE_RESP=$(uv run python oauth2/admin_workflow.py delete "$NEW_ID")
echo "    $DELETE_RESP"

echo ""
printf "${BOLD}>>> Employees AFTER DELETE (restored to original)${RESET}\n"
_show_employees

echo ""
echo "============================================"
echo " Both operations succeeded. Database state is restored."
echo " - insert_employee succeeded (Catalyst MCPServer access: admin allowed"
echo "   + Catalyst's own JWT satisfied the bearer middleware)"
echo " - delete_employee succeeded (same two gates)"
echo "============================================"
