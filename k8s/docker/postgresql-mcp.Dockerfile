# Combined MCP server image. All tools (query, insert_employee, update_salary,
# delete_employee, truncate_table) run in one process. Per-tool DB users are
# passed as separate env vars at runtime.
#
# Build context must be the repo root:
#   docker build -f k8s/docker/postgresql-mcp.Dockerfile -t secure-postgresql-mcp:dev .

FROM python:3.12-slim

WORKDIR /app

# psycopg2-binary brings its own libpq, so we don't need libpq-dev at runtime
# pyjwt[crypto] is needed for postgresql_mcp.py's own Keycloak JWT verification
# (RS256 signature checking against Keycloak's JWKS) — see README.md's
# "OIDC / bearer middleware" section. Installed from servers/requirements.txt
# so the mcp version pin (see that file) doesn't drift from what's built here.
COPY servers/requirements.txt /app/servers/requirements.txt
RUN pip install --no-cache-dir -r /app/servers/requirements.txt httpx

COPY servers/ /app/servers/

WORKDIR /app/servers

ENV PYTHONUNBUFFERED=1

CMD ["python", "postgresql_mcp.py"]
