#!/usr/bin/env bash
# Restore the deny policies on a per-op MCP server's Catalyst Configuration.
# Pairs with scripts/grant.sh.
#
# Usage:
#   ./scripts/revoke.sh write   # analyst denied again
#   ./scripts/revoke.sh ddl     # analyst + ops denied again

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
        POLICIES=(--policy analyst-agent:deny)
        DESCRIPTION="analyst-agent denied"
        ;;
    ddl)
        CONFIG="db-ddl-restricted"
        POLICIES=(--policy analyst-agent:deny --policy ops-agent:deny)
        DESCRIPTION="analyst-agent + ops-agent denied"
        ;;
    *)
        echo "ERROR: op must be 'write' or 'ddl'" >&2
        exit 2 ;;
esac

echo ">>> Restoring restricted policy on mcp-db-${OP} (${DESCRIPTION})"
echo "    diagrid configuration update ${CONFIG} --default-action allow ${POLICIES[*]}"
diagrid configuration update "$CONFIG" --project "$PROJECT" \
    --default-action allow "${POLICIES[@]}"

echo ">>> Waiting 5s for policy propagation..."
sleep 5

echo ">>> Done."
