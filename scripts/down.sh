#!/usr/bin/env bash
# Revoke every agent's access on every per-op server — back to deny-all
# baseline. Useful between rehearsals or before the live demo to guarantee
# a clean starting state.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "============================================"
echo " Tearing down all grants — back to deny-all"
echo "============================================"

./scripts/revoke.sh schema  analyst ops admin
./scripts/revoke.sh query   analyst ops admin
./scripts/revoke.sh write   analyst ops admin
./scripts/revoke.sh ddl     analyst ops admin

echo ""
echo "============================================"
echo " Down — every operation now denied"
echo "============================================"
echo ""
echo " Run ./run_demo.sh to confirm the matrix is all ✗."
