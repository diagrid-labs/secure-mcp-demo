#!/usr/bin/env bash
# Runs the matrix probe for one or all agent roles.
#
# Usage:
#   ./run_demo.sh              # all three roles
#   ./run_demo.sh analyst      # only analyst
#   ./run_demo.sh ops
#   ./run_demo.sh admin
#
# Bypasses `diagrid dev run` for the agents: each agent is a one-shot script
# that doesn't need a tunnel, and creating per-agent dev sessions corrupts
# the server-side tunnels (see KNOWN_ISSUES.md). Instead we read each
# agent's Catalyst API token from `diagrid appid get` and call probe.py
# directly with DAPR_HTTP_ENDPOINT / DAPR_API_TOKEN in env.
#
# Servers still run under `diagrid dev run -f dev.yaml` — Diagrid is the
# inbound/multi-app showcase. Only the transient agent invocations bypass.
#
# Prerequisite: servers running in another terminal under
#   diagrid dev run --project secure-mcp-demo -f dev.yaml

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

if [ $# -eq 0 ]; then
    ROLES=(analyst ops admin)
elif [ $# -eq 1 ]; then
    case "$1" in
        analyst|ops|admin) ROLES=("$1") ;;
        *)
            echo "ERROR: role must be analyst|ops|admin" >&2
            exit 2 ;;
    esac
else
    echo "Usage: $0 [analyst|ops|admin]" >&2
    exit 2
fi

_jq_path() {
    # Usage: _jq_path <json-string> <dot-path>
    uv run python -c "
import json, sys
d = json.loads(sys.argv[1])
for key in sys.argv[2].split('.'):
    d = d.get(key) if isinstance(d, dict) else None
print(d or '')
" "$1" "$2"
}

echo "============================================"
echo " secure-mcp matrix probe — project: $PROJECT"
echo "============================================"

PROJECT_JSON=$(diagrid project get "$PROJECT" --output json)
DAPR_HTTP_ENDPOINT=$(_jq_path "$PROJECT_JSON" "status.endpoints.http.url")
echo "Catalyst endpoint: $DAPR_HTTP_ENDPOINT"

for role in "${ROLES[@]}"; do
    APPID_JSON=$(diagrid appid get "${role}-agent" --project "$PROJECT" --output json)
    TOKEN=$(_jq_path "$APPID_JSON" "status.apiToken")

    DAPR_HTTP_ENDPOINT="$DAPR_HTTP_ENDPOINT" \
    DAPR_API_TOKEN="$TOKEN" \
    AGENT_ROLE="$role" \
        uv run python agents/probe.py
done

echo ""
echo "============================================"
echo " Done"
echo "============================================"
