#!/usr/bin/env bash
# Live-grant access to a per-op MCP server by overriding the deny policies
# on its Catalyst Configuration. The same config name (db-<op>-restricted)
# stays attached to the app-id — no `diagrid appid update`, no dev-session
# conflict.
#
# Diagrid's `configuration update --policy` overrides the existing entry
# for that appId. We flip deny → allow.
#
# Usage:
#   ./scripts/grant.sh write    # analyst-agent can now invoke mcp-db-write
#   ./scripts/grant.sh ddl      # analyst + ops can now invoke mcp-db-ddl
#
# To revert: ./scripts/revoke.sh <op>

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <write|ddl>" >&2
    exit 2
fi

OP=$1
PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

case "$OP" in
    write)
        CONFIG="db-write-restricted"
        POLICIES=(--policy analyst-agent:allow)
        DESCRIPTION="analyst-agent allowed"
        ;;
    ddl)
        CONFIG="db-ddl-restricted"
        POLICIES=(--policy analyst-agent:allow --policy ops-agent:allow)
        DESCRIPTION="analyst-agent + ops-agent allowed"
        ;;
    *)
        echo "ERROR: op must be 'write' or 'ddl' (schema/query are always allow)" >&2
        exit 2 ;;
esac

echo ">>> Granting access on mcp-db-${OP} (${DESCRIPTION})"
echo "    diagrid configuration update ${CONFIG} --default-action allow ${POLICIES[*]}"
diagrid configuration update "$CONFIG" --project "$PROJECT" \
    --default-action allow "${POLICIES[@]}"

echo ">>> Waiting 5s for policy propagation..."
sleep 5

echo ">>> Done. Re-run ./run_demo.sh analyst to see the flip."
