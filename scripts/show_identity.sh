#!/usr/bin/env bash
# Print each app-id's Catalyst-issued API token prefix + SHA-256 fingerprint.
# Demonstrates that identities are unique cryptographic credentials, not
# strings in a policy file.
#
# Usage:
#   ./scripts/show_identity.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="${DIAGRID_PROJECT:-secure-mcp-demo}"

APPIDS=(
    mcp-db-query
    mcp-db-write
    mcp-db-delete
    analyst-agent
    ops-agent
    admin-agent
)

echo "==========================================="
echo " App-ID identities — Catalyst-issued tokens"
echo " project: $PROJECT"
echo "==========================================="
echo ""
printf "%-18s  %-16s  %s\n" "APP-ID" "TOKEN PREFIX" "SHA-256 FINGERPRINT"
printf "%-18s  %-16s  %s\n" "------" "------------" "-------------------"

for appid in "${APPIDS[@]}"; do
    TOKEN=$(diagrid appid get "$appid" --project "$PROJECT" -o json | \
        uv run python -c "import json,sys; print(json.loads(sys.stdin.read()).get('status',{}).get('apiToken',''))")
    PREFIX="${TOKEN:0:10}..."
    FINGERPRINT=$(printf '%s' "$TOKEN" | shasum -a 256 | cut -c1-16)
    printf "%-18s  %-16s  %s\n" "$appid" "$PREFIX" "$FINGERPRINT"
done

echo ""
echo "Each app-id has a distinct token. ACL rules reference app-id names,"
echo "but the *identity* enforced at the wire is the token — and Catalyst"
echo "validates token → app-id binding before any policy check runs."
