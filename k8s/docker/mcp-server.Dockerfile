# Combined MCP server image. All tools (query, insert_employee, update_salary,
# delete_employee, truncate_table) run in one process. Per-tool DB users are
# passed as separate env vars at runtime.
#
# Build context must be the repo root:
#   docker build -f k8s/docker/mcp-server.Dockerfile -t secure-mcp-server:dev .

FROM python:3.12-slim

WORKDIR /app

# psycopg2-binary brings its own libpq, so we don't need libpq-dev at runtime
# pyjwt[crypto] is needed for mcp_server.py's own Keycloak JWT verification
# (RS256 signature checking against Keycloak's JWKS) — see README.md's
# "OIDC / bearer middleware" section.
RUN pip install --no-cache-dir \
        mcp \
        httpx \
        psycopg2-binary \
        "pyjwt[crypto]"

COPY servers/ /app/servers/

WORKDIR /app/servers

ENV PYTHONUNBUFFERED=1

CMD ["python", "mcp_server.py"]
