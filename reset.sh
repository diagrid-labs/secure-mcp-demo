#!/usr/bin/env bash
# Force-stop all dev sessions for this project's app-ids AND kill any
# orphaned local server processes still bound to the MCP server ports.
#
# Run before `diagrid dev run -f dev.yaml` if you're seeing:
#   - HTTP 502s on calls that should pass (stale Catalyst tunnels)
#   - "address already in use" errors at server startup (orphaned Python
#     processes from prior diagrid dev run cycles)
#
# Idempotent and safe to run anytime. Doesn't touch app-ids,
# configurations, or Postgres state.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

APP_IDS=(
    mcp-db-query
    mcp-db-write
    mcp-db-delete
    analyst-agent
    ops-agent
    admin-agent
)

# Server ports — must match dev.yaml / servers/db_*.py
SERVER_PORTS=(8001 8003 8004)

echo ">>> Stopping any active dev sessions for project: $PROJECT"
for appid in "${APP_IDS[@]}"; do
    diagrid dev stop --app-id "$appid" --project "$PROJECT" 2>/dev/null || true
done

echo ""
echo ">>> Killing any orphaned processes on MCP server ports (${SERVER_PORTS[*]})"
for port in "${SERVER_PORTS[@]}"; do
    pids=$(lsof -ti ":$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "  port $port: killing $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
done

echo ""
echo ">>> Current dev status:"
diagrid dev status
