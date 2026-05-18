#!/usr/bin/env bash
# Grant one or more agents access to a per-op MCP server.
#
# Reads the current configuration, sets the named agents' entries to
# `allow`, and writes back with the full merged policy list. This is
# additive — grants for *other* agents on the same config are preserved.
# (`diagrid configuration update --policy` is a replace, not a merge, so
# we have to round-trip through get → modify → update.)
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

for agent in "${AGENTS[@]}"; do
    case "$agent" in
        analyst|ops|admin) ;;
        *) echo "ERROR: agent must be analyst|ops|admin (got '$agent')" >&2; exit 2 ;;
    esac
done

CONFIG="db-${OP}"

# Read current policies, override the named agents to allow, emit the
# full merged --policy flag set.
AGENTS_CSV=$(IFS=,; echo "${AGENTS[*]}")
FLAGS=$(diagrid configuration get "$CONFIG" --project "$PROJECT" -o json | uv run python -c "
import json, sys
data = json.load(sys.stdin)
policies = data.get('spec', {}).get('accessControl', {}).get('policies', []) or []
state = {p['appId']: p['defaultAction'] for p in policies}
for agent in sys.argv[1].split(','):
    state[f'{agent}-agent'] = 'allow'
print(' '.join(f'--policy {a}:{act}' for a, act in state.items()))
" "$AGENTS_CSV")

echo ">>> Granting [${AGENTS[*]}] access to mcp-db-${OP}"
echo "    diagrid configuration update ${CONFIG} --default-action deny ${FLAGS}"
diagrid configuration update "$CONFIG" --project "$PROJECT" \
    --default-action deny $FLAGS

echo ">>> Waiting 5s for policy propagation..."
sleep 5

echo ">>> Done."
