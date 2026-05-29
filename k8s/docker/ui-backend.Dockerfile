# UI backend image — FastAPI app + static UI files. Bundles the diagrid CLI
# so policy/apply + identity fetches can shell out the same way local dev does.
# In a hardened deploy you'd swap shelling-out for the Catalyst REST API directly.
#
# Build context must be the repo root:
#   docker build -f k8s/docker/ui-backend.Dockerfile -t secure-mcp-ui:dev .

FROM python:3.12-slim

# --- diagrid CLI -----------------------------------------------------------
# The UI backend shells out to `diagrid` for policy reads/writes and
# app-id token lookups. Pin a version to keep deploys reproducible.
ARG DIAGRID_VERSION=1.4.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL "https://downloads.diagrid.io/cli/install.sh" | bash -s -- v${DIAGRID_VERSION} \
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
