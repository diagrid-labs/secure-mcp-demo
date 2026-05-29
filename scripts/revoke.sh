#!/usr/bin/env bash
# Revoke one or more agents' access to a per-op MCP server.
#
# Reads the current configuration, sets the named agents' entries to
# `deny`, and writes back with the full merged policy list. Other agents'
# entries are preserved.
#
# Usage:
#   ./scripts/revoke.sh <op> <agent>...
#
#   op:    query | write | delete
#   agent: analyst | ops | admin (one or more)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <query|write|delete> <analyst|ops|admin>..." >&2
    exit 2
fi

OP=$1; shift
AGENTS=("$@")

case "$OP" in
    query|write|delete) ;;
    *) echo "ERROR: op must be query|write|delete (got '$OP')" >&2; exit 2 ;;
esac

for agent in "${AGENTS[@]}"; do
    case "$agent" in
        analyst|ops|admin) ;;
        *) echo "ERROR: agent must be analyst|ops|admin (got '$agent')" >&2; exit 2 ;;
    esac
done

CONFIG="db-${OP}"

AGENTS_CSV=$(IFS=,; echo "${AGENTS[*]}")
FLAGS=$(diagrid configuration get "$CONFIG" --project "$PROJECT" -o json | uv run python -c "
import json, sys
data = json.load(sys.stdin)
policies = data.get('spec', {}).get('accessControl', {}).get('policies', []) or []
state = {p['appId']: p['defaultAction'] for p in policies}
for agent in sys.argv[1].split(','):
    state[f'{agent}-agent'] = 'deny'
print(' '.join(f'--policy {a}:{act}' for a, act in state.items()))
" "$AGENTS_CSV")

echo ">>> Revoking [${AGENTS[*]}] access to mcp-db-${OP}"
echo "    diagrid configuration update ${CONFIG} --default-action deny ${FLAGS}"
diagrid configuration update "$CONFIG" --project "$PROJECT" \
    --default-action deny $FLAGS

echo ">>> Waiting 5s for policy propagation..."
sleep 5

echo ">>> Done."
