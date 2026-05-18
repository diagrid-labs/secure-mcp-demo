#!/usr/bin/env bash
# Revoke one or more agents' access to a per-op MCP server.
#
# Mutates the configuration in place — flips the named agent's policy entry
# from `allow` to `deny`. Grants for *other* agents on this config are
# preserved.
#
# Usage:
#   ./scripts/revoke.sh <op> <agent>...
#
#   op:    schema | query | write | ddl
#   agent: analyst | ops | admin (one or more)
#
# Examples:
#   ./scripts/revoke.sh write  analyst
#   ./scripts/revoke.sh ddl    admin

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <schema|query|write|ddl> <analyst|ops|admin>..." >&2
    exit 2
fi

OP=$1; shift
AGENTS=("$@")

case "$OP" in
    schema|query|write|ddl) ;;
    *) echo "ERROR: op must be schema|query|write|ddl (got '$OP')" >&2; exit 2 ;;
esac

POLICIES=()
for agent in "${AGENTS[@]}"; do
    case "$agent" in
        analyst|ops|admin) POLICIES+=(--policy "${agent}-agent:deny") ;;
        *) echo "ERROR: agent must be analyst|ops|admin (got '$agent')" >&2; exit 2 ;;
    esac
done

CONFIG="db-${OP}"

echo ">>> Revoking [${AGENTS[*]}] access to mcp-db-${OP}"
echo "    diagrid configuration update ${CONFIG} --default-action deny ${POLICIES[*]}"
diagrid configuration update "$CONFIG" --project "$PROJECT" \
    --default-action deny "${POLICIES[@]}"

echo ">>> Waiting 5s for policy propagation..."
sleep 5

echo ">>> Done."
