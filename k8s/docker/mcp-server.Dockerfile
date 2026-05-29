# Single image used by all 3 MCP servers. The Deployment chooses which
# entry point to run via `command:` (e.g. `python servers/db_query.py`),
# so the only differences between mcp-db-query / mcp-db-write / mcp-db-delete
# at runtime are: command args, container port, and DB_USER/DB_PASSWORD env.
#
# Build context must be the repo root:
#   docker build -f k8s/docker/mcp-server.Dockerfile -t secure-mcp-server:dev .

FROM python:3.12-slim

WORKDIR /app

# psycopg2-binary brings its own libpq, so we don't need libpq-dev at runtime
RUN pip install --no-cache-dir \
        mcp \
        httpx \
        psycopg2-binary

# Copy only what the per-op servers need.
COPY servers/ /app/servers/

WORKDIR /app/servers

# The default command is mcp-db-query; the Deployment overrides this for
# write and delete. UI_BACKEND_URL is passed via env so heartbeats can find
# the UI backend Service inside the cluster.
ENV PYTHONUNBUFFERED=1

CMD ["python", "db_query.py"]
