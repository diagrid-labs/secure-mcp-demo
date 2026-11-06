#!/usr/bin/env bash
# Stop all dev sessions for this project's app-ids and kill any orphaned
# local server process still bound to the MCP server port. Run before
# `diagrid dev run -f dev.yaml` if you see stale-tunnel 502s or
# "address already in use" at startup. Doesn't touch Diagrid resources.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

APP_IDS=(
    postgresql-mcp
    analyst-mcp-client
    ops-mcp-client
    admin-mcp-client
)

SERVER_PORT=8001  # must match dev.yaml / servers/postgresql_mcp.py

echo ">>> Stopping any active dev sessions for project: $PROJECT"
for appid in "${APP_IDS[@]}"; do
    diagrid dev stop --app-id "$appid" --project "$PROJECT" 2>/dev/null || true
done

echo ""
echo ">>> Killing any orphaned process on MCP server port ($SERVER_PORT)"
pids=$(lsof -ti ":$SERVER_PORT" 2>/dev/null || true)
if [ -n "$pids" ]; then
    echo "  port $SERVER_PORT: killing $pids"
    echo "$pids" | xargs kill -9 2>/dev/null || true
fi

echo ""
echo ">>> Current dev status:"
diagrid dev status
