"""Combined MCP server for all database operations.

All tools (query, insert_employee, update_salary, delete_employee,
truncate_table) are exposed through a single FastMCP endpoint. Each tool
connects using its own dedicated Postgres user so per-operation DB-level
enforcement is preserved. Diagrid enforces which tools each caller is
allowed to invoke via the MCPServer access policy.

Every call must also carry a valid Keycloak-issued bearer JWT, verified
below against Keycloak's JWKS (signature + issuer + audience). Nothing
issues that JWT except Diagrid itself, via OAuth2 client-credentials
configured directly on the MCPServer resource (see ../oauth2/setup.sh) —
per https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials.
No agent ever fetches or presents one. This verification happens here, in
application code, because MCPServer-resource-routed calls have no Dapr
sidecar to enforce it at the platform level — see README.md's "OIDC /
bearer middleware" section for why the old Dapr bearer-middleware approach
doesn't apply to this resource type.
"""
import os

import jwt
import psycopg2
from jwt import PyJWKClient
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP

from common import heartbeat

SERVER = "postgresql-mcp"

KEYCLOAK_PUBLIC_URL = os.environ.get("KEYCLOAK_PUBLIC_URL", "http://localhost:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "secure-mcp")
KEYCLOAK_AUDIENCE = os.environ.get("KEYCLOAK_AUDIENCE", "https://secure-mcp-demo/")
KEYCLOAK_ISSUER = f"{KEYCLOAK_PUBLIC_URL}/realms/{KEYCLOAK_REALM}"
KEYCLOAK_JWKS_URL = f"{KEYCLOAK_ISSUER}/protocol/openid-connect/certs"

# Lazily fetches + caches Keycloak's signing keys on first use — doesn't
# require Keycloak to be reachable at import time, so pod/process startup
# ordering doesn't matter.
_jwks_client = PyJWKClient(KEYCLOAK_JWKS_URL, cache_keys=True)


class KeycloakTokenVerifier(TokenVerifier):
    """Verifies the bearer token on every call against Keycloak's JWKS.

    Returns None (-> the SDK responds 401) on any missing, malformed,
    expired, or wrong-issuer/audience token. This is the sole enforcement
    point for "does this call carry a valid JWT" — see module docstring.
    """

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            signing_key = _jwks_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                audience=KEYCLOAK_AUDIENCE,
                issuer=KEYCLOAK_ISSUER,
            )
        except jwt.PyJWTError:
            return None

        return AccessToken(
            token=token,
            client_id=claims.get("azp") or claims.get("client_id") or "unknown",
            scopes=[],
            expires_at=claims.get("exp"),
            subject=claims.get("sub"),
            claims=claims,
        )


mcp = FastMCP(
    SERVER,
    host="0.0.0.0",
    port=8001,
    stateless_http=True,
    token_verifier=KeycloakTokenVerifier(),
    auth=AuthSettings(
        issuer_url=KEYCLOAK_ISSUER,
        resource_server_url=KEYCLOAK_AUDIENCE,
    ),
)

# Per-operation Postgres users — each has only the privileges its tools need.
_DB_CREDS = {
    "query":  (os.environ.get("DB_USER_QUERY",  "mcp_db_query"),  os.environ.get("DB_PASSWORD_QUERY",  "")),
    "write":  (os.environ.get("DB_USER_WRITE",  "mcp_db_write"),  os.environ.get("DB_PASSWORD_WRITE",  "")),
    "delete": (os.environ.get("DB_USER_DELETE", "mcp_db_delete"), os.environ.get("DB_PASSWORD_DELETE", "")),
}


def _conn(op: str):
    user, password = _DB_CREDS[op]
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "demo"),
        user=user,
        password=password,
    )


# ── Query ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def query(sql: str) -> str:
    """Execute a read-only SQL query against the demo database."""
    with _conn("query") as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            cols = [d[0] for d in cur.description] if cur.description else []
            rows = cur.fetchall()
            body = str([dict(zip(cols, row)) for row in rows])
            heartbeat(SERVER, "query", {"sql": sql}, body=body)
            return body


# ── Write ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def insert_employee(name: str, email: str, department_id: int, salary: float) -> str:
    """Insert a new employee. Returns the new id."""
    args = {"name": name, "email": email, "department_id": department_id, "salary": salary}
    with _conn("write") as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO employees (name, email, department_id, salary) "
                "VALUES (%s, %s, %s, %s) RETURNING id",
                (name, email, department_id, salary),
            )
            new_id = cur.fetchone()[0]
            conn.commit()
            body = f"Inserted employee id={new_id}"
            heartbeat(SERVER, "insert_employee", args, body=body)
            return body


@mcp.tool()
def update_salary(employee_id: int, new_salary: float) -> str:
    """Update an existing employee's salary."""
    args = {"employee_id": employee_id, "new_salary": new_salary}
    with _conn("write") as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE employees SET salary = %s WHERE id = %s",
                (new_salary, employee_id),
            )
            rowcount = cur.rowcount
            conn.commit()
            body = f"Updated {rowcount} row(s)"
            heartbeat(SERVER, "update_salary", args, body=body)
            return body


# ── Delete ────────────────────────────────────────────────────────────────────

@mcp.tool()
def delete_employee(employee_id: int) -> str:
    """Delete an employee by id. Destructive."""
    args = {"employee_id": employee_id}
    with _conn("delete") as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM employees WHERE id = %s", (employee_id,))
            rowcount = cur.rowcount
            conn.commit()
            body = f"Deleted {rowcount} row(s)"
            heartbeat(SERVER, "delete_employee", args, body=body)
            return body


@mcp.tool()
def truncate_table(table: str) -> str:
    """Truncate a table — removes all rows. Destructive, irreversible."""
    args = {"table": table}
    with _conn("delete") as conn:
        with conn.cursor() as cur:
            cur.execute(f'TRUNCATE TABLE "{table}" RESTART IDENTITY CASCADE')
            conn.commit()
            body = f"Truncated {table}"
            heartbeat(SERVER, "truncate_table", args, body=body)
            return body


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
