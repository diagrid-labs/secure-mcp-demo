#!/usr/bin/env bash
# Demonstrates an admin destructive workflow end-to-end with visible state:
#   1. Show DB state (5 rows)
#   2. Admin inserts "Demo Target" via mcp-db-write
#   3. Show DB state (6 rows — Demo Target visible)
#   4. Admin deletes "Demo Target" via mcp-db-delete (requires JWT)
#   5. Show DB state (5 rows — restored)
#
# Both operations require admin's Catalyst token. The delete additionally
# requires a valid Keycloak JWT. Self-resetting — safe to re-run.
#
# Prereqs:
#   - ./scripts/up.sh (admin granted on write + delete)
#   - Keycloak running and reachable; KEYCLOAK_* env vars set

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

: "${KEYCLOAK_URL:?ERROR: KEYCLOAK_URL must be set (export the agent JWT vars)}"
: "${KEYCLOAK_REALM:?ERROR: KEYCLOAK_REALM must be set}"
: "${KEYCLOAK_CLIENT_ID:?ERROR: KEYCLOAK_CLIENT_ID must be set}"
: "${KEYCLOAK_CLIENT_SECRET:?ERROR: KEYCLOAK_CLIENT_SECRET must be set}"

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
printf "${BOLD}>>> Fetching admin's Catalyst token + Keycloak JWT...${RESET}\n"
export DAPR_HTTP_ENDPOINT=$(diagrid project get "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['endpoints']['http']['url'])")
export DAPR_API_TOKEN=$(diagrid appid get admin-agent --project "$PROJECT" -o json | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['status']['apiToken'])")
export KEYCLOAK_JWT=$(curl -s -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=$KEYCLOAK_CLIENT_ID" \
    -d "client_secret=$KEYCLOAK_CLIENT_SECRET" | \
    uv run python -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
printf "    ${DIM}Catalyst endpoint: $DAPR_HTTP_ENDPOINT${RESET}\n"
printf "    ${DIM}Admin token:       ${DAPR_API_TOKEN:0:10}...${RESET}\n"
printf "    ${DIM}Keycloak JWT:      ${KEYCLOAK_JWT:0:32}...${RESET}\n"

# If a prior run inserted Demo Target but couldn't delete it (e.g. the
# JWT layer rejected the delete call), the unique-email constraint blocks
# this run's INSERT. Clear any stray row so BEFORE always shows the
# canonical 5-row state.
docker exec secure-mcp-postgres psql -U postgres demo -c \
    "DELETE FROM employees WHERE email='demo-target@example.com';" \
    >/dev/null 2>&1 || true

echo ""
printf "${BOLD}>>> Employees BEFORE${RESET}\n"
_show_employees

echo ""
printf "${BOLD}>>> Admin inserts a new employee via mcp-db-write...${RESET}\n"
NEW_ID_RAW=$(uv run python oauth2/admin_workflow.py insert)
echo "    $NEW_ID_RAW"
NEW_ID=$(echo "$NEW_ID_RAW" | sed -E 's/^id=([0-9]+).*/\1/')

echo ""
printf "${BOLD}>>> Employees AFTER INSERT (Demo Target visible)${RESET}\n"
_show_employees

echo ""
printf "${BOLD}>>> Admin deletes Demo Target via mcp-db-delete...${RESET}\n"
printf "    ${DIM}(this call requires BOTH Catalyst ACL allow AND a valid Keycloak JWT)${RESET}\n"
DELETE_RESP=$(uv run python oauth2/admin_workflow.py delete "$NEW_ID")
echo "    $DELETE_RESP"

echo ""
printf "${BOLD}>>> Employees AFTER DELETE (restored to original)${RESET}\n"
_show_employees

echo ""
echo "============================================"
echo " Both operations succeeded. Database state is restored."
echo " - mcp-db-write inserted (Catalyst ACL allow)"
echo " - mcp-db-delete removed it (Catalyst ACL allow + valid Keycloak JWT)"
echo "============================================"
