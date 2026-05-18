#!/usr/bin/env bash
# Grant one or more agents access to a per-op MCP server.
#
# Mutates the configuration in place via `diagrid configuration update`.
# Each call sets `default-action: deny` (unchanged) and adds explicit
# `<agent>-agent:allow` policy entries. Existing grants for *other* agents
# on this config are preserved.
#
# Usage:
#   ./scripts/grant.sh <op> <agent>...
#
#   op:    schema | query | write | ddl
#   agent: analyst | ops | admin (one or more)
#
# Examples:
#   ./scripts/grant.sh schema  analyst ops admin
#   ./scripts/grant.sh write   ops admin
#   ./scripts/grant.sh ddl     admin

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
        analyst|ops|admin) POLICIES+=(--policy "${agent}-agent:allow") ;;
        *) echo "ERROR: agent must be analyst|ops|admin (got '$agent')" >&2; exit 2 ;;
    esac
done

CONFIG="db-${OP}"

echo ">>> Granting [${AGENTS[*]}] access to mcp-db-${OP}"
echo "    diagrid configuration update ${CONFIG} --default-action deny ${POLICIES[*]}"
diagrid configuration update "$CONFIG" --project "$PROJECT" \
    --default-action deny "${POLICIES[@]}"

echo ">>> Waiting 5s for policy propagation..."
sleep 5

echo ">>> Done."
