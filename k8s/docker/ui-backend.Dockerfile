# UI backend image — FastAPI app + static UI files. Bundles the diagrid CLI
# so policy/apply + identity fetches can shell out the same way local dev does.
# In a hardened deploy you'd swap shelling-out for the Diagrid REST API directly.
#
# Build context must be the repo root:
#   docker build -f k8s/docker/ui-backend.Dockerfile -t secure-mcp-ui:dev .

FROM python:3.12-slim

# --- diagrid CLI -----------------------------------------------------------
# The UI backend shells out to `diagrid` for policy reads/writes and
# app-id token lookups. Pin a version to keep deploys reproducible.
#
# install.sh only reads a $RELEASE_VERSION env var, not a positional arg —
# `bash -s -- v1.4.0` silently ignores that "v1.4.0" and falls back to
# whatever default is baked into the script. It also never installs the
# binary anywhere; it just extracts `diagrid` into the current directory
# and tells you to move it into $PATH yourself. Do both explicitly, or the
# binary silently doesn't exist at runtime (confirmed: every diagrid-CLI
# code path in ui_backend failed with "not found in $PATH", including the
# ACL matrix read and the JWT step-up toggle).
ARG DIAGRID_VERSION=v1.54.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && cd /tmp \
 && RELEASE_VERSION=${DIAGRID_VERSION} bash -c "$(curl -fsSL https://downloads.diagrid.io/cli/install.sh)" \
 && mv /tmp/diagrid /usr/local/bin/diagrid \
 && chmod +x /usr/local/bin/diagrid \
 && cd / \
 && apt-get purge -y curl && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# --- App -------------------------------------------------------------------
WORKDIR /app

COPY ui_backend/requirements.txt /app/ui_backend/requirements.txt
RUN pip install --no-cache-dir -r /app/ui_backend/requirements.txt

# Source + the UI static files
COPY ui_backend/main.py                       /app/ui_backend/main.py
COPY ui/                                      /app/ui/

ENV PYTHONUNBUFFERED=1
ENV UI_BACKEND_PORT=5050

WORKDIR /app/ui_backend

EXPOSE 5050

# `diagrid` requires an API key + project. Pass via env / secret at
# deploy time:  DIAGRID_API_KEY, DIAGRID_PROJECT.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5050"]
