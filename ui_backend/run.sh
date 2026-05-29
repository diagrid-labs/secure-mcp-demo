#!/usr/bin/env bash
# Start the secure-mcp demo UI backend.
#
# Prereqs:
#   - Postgres running (docker-compose up -d postgres)
#   - diagrid CLI logged in and project = secure-mcp-demo
#
# First run:
#   uv venv && uv pip install -r requirements.txt
#
# Then:
#   ./run.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${UI_BACKEND_PORT:-5050}"

uv run uvicorn main:app --reload --port "$PORT" --host 127.0.0.1
