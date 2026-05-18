#!/usr/bin/env bash
# Apply the canonical demo policy matrix in one shot:
#
#   schema: all three agents
#   query:  all three agents
#   write:  ops + admin
#   ddl:    admin only
#
# Convenience for rehearsal and "reset to known good state" — for the live
# demo, type the individual grant.sh commands so the audience sees each
# capability being granted.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "============================================"
echo " Applying canonical demo policy matrix"
echo "============================================"

./scripts/grant.sh schema  analyst ops admin
./scripts/grant.sh query   analyst ops admin
./scripts/grant.sh write   ops admin
./scripts/grant.sh ddl     admin

echo ""
echo "============================================"
echo " Up — canonical matrix applied"
echo "============================================"
echo ""
echo " Run ./run_demo.sh to see the matrix."
