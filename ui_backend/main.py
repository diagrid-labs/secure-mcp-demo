"""secure-mcp demo UI backend.

Thin HTTP wrapper around the existing demo plumbing (diagrid CLI, Postgres,
Keycloak). Serves the demo UI static files and exposes /api/* routes the UI's
state.jsx calls into.

Run:
    cd ui_backend
    uv pip install -r requirements.txt   # one-time
    uv run uvicorn main:app --reload --port 5050

Then open http://localhost:5050/
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
from collections import deque
from pathlib import Path

import psycopg2
import psycopg2.extras
from fastapi import Body, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sse_starlette.sse import EventSourceResponse

REPO_ROOT = Path(__file__).resolve().parent.parent
STATIC_DIR = REPO_ROOT / "ui"

PROJECT = os.environ.get("DIAGRID_PROJECT", "secure-mcp-demo")

AGENTS = ["analyst-mcp-client", "ops-mcp-client", "admin-mcp-client"]
SERVERS = ["postgresql-mcp"]

# All operations are served by the single combined MCP server.
OP_TO_SERVER = {
    "query":  "postgresql-mcp",
    "write":  "postgresql-mcp",
    "delete": "postgresql-mcp",
}

# Tools that belong to each logical operation — used for grant/revoke.
OP_TO_TOOLS = {
    "query":  ["query"],
    "write":  ["insert_employee", "update_salary"],
    "delete": ["delete_employee", "truncate_table"],
}

app = FastAPI(title="secure-mcp demo UI backend")


# ─── Event bus (Phase 3) ─────────────────────────────────────────────────
# In-memory ring of recent tool-invocation heartbeats + a list of asyncio
# queues for currently-connected SSE subscribers.

_event_log: deque[dict] = deque(maxlen=256)
_subscribers: list[asyncio.Queue] = []


def _publish_event(evt: dict) -> None:
    evt = {**evt, "ts": evt.get("ts") or time.time(), "tHHMMSS": time.strftime("%H:%M:%S")}
    _event_log.append(evt)
    dead = []
    for q in _subscribers:
        try:
            q.put_nowait(evt)
        except asyncio.QueueFull:
            dead.append(q)
    for q in dead:
        try:
            _subscribers.remove(q)
        except ValueError:
            pass


def _recent_heartbeat(server: str, tool: str, within_seconds: float = 2.5) -> dict | None:
    """Find the most recent heartbeat for (server, tool) within a window."""
    cutoff = time.time() - within_seconds
    for evt in reversed(_event_log):
        if evt.get("ts", 0) < cutoff:
            break
        if evt.get("server") == server and evt.get("tool") == tool:
            return evt
    return None


# ─── helpers ──────────────────────────────────────────────────────────────

def _run_diagrid_capture(cmd: list[str]) -> subprocess.CompletedProcess:
    """Run a diagrid CLI command, retrying once on a transient empty-stdout
    result (observed intermittently under this pod's concurrent request
    load — exit 0 but no output, not reproducible as a simple rate limit or
    concurrency race; a single immediate retry has reliably recovered it in
    testing). Raises HTTPException for anything that isn't a transient blip.
    """
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
    except FileNotFoundError:
        raise HTTPException(status_code=502, detail="diagrid CLI not found in UI backend image")
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=502, detail=f"diagrid command failed: {e.stderr.strip()}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="diagrid command timed out")

    if not out.stdout.strip():
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
        except FileNotFoundError:
            raise HTTPException(status_code=502, detail="diagrid CLI not found in UI backend image")
        except subprocess.CalledProcessError as e:
            raise HTTPException(status_code=502, detail=f"diagrid command failed: {e.stderr.strip()}")
        except subprocess.TimeoutExpired:
            raise HTTPException(status_code=504, detail="diagrid command timed out")
        if not out.stdout.strip():
            raise HTTPException(status_code=502, detail=f"diagrid returned no output for: {' '.join(cmd)}")

    return out


def _diagrid_json(*args: str) -> dict:
    """Run a diagrid CLI command and parse its JSON output."""
    cmd = ["diagrid", *args, "--project", PROJECT, "--output", "json"]
    out = _run_diagrid_capture(cmd)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise HTTPException(status_code=502, detail=f"diagrid returned invalid JSON for: {' '.join(cmd)}")


def _diagrid_project_get() -> dict:
    """`diagrid project get` takes project as positional, not a flag."""
    cmd = ["diagrid", "project", "get", PROJECT, "--output", "json"]
    out = _run_diagrid_capture(cmd)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise HTTPException(status_code=502, detail=f"diagrid returned invalid JSON for: {' '.join(cmd)}")


def _fingerprint(token: str) -> str:
    return "sha256:" + hashlib.sha256(token.encode()).hexdigest()


def _mask_dapr_token(t: str, prefix: int = 16, suffix: int = 8) -> str:
    if not t:
        return ""
    if len(t) <= prefix + suffix + 1:
        return t
    return f"{t[:prefix]}…{t[-suffix:]}"


def _mask_jwt(t: str, prefix: int = 24) -> str:
    if not t:
        return ""
    return f"{t[:prefix]}…"


def _headers_sent(catalyst_token: str | None, jwt_token: str | None) -> dict:
    out: dict[str, str] = {}
    if catalyst_token:
        out["dapr-api-token"] = _mask_dapr_token(catalyst_token)
    if jwt_token:
        out["Authorization"] = "Bearer " + _mask_jwt(jwt_token)
    return out


def _b64url_decode(segment: str) -> bytes:
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def _decode_jwt_for_display(token: str) -> tuple[dict, dict]:
    """Split a compact JWT into (header, claims) dicts for display only —
    no signature verification. Real verification happens server-side in
    servers/postgresql_mcp.py's KeycloakTokenVerifier against Keycloak's JWKS.
    """
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError(f"expected 3 dot-separated segments, got {len(parts)}")
    header = json.loads(_b64url_decode(parts[0]))
    claims = json.loads(_b64url_decode(parts[1]))
    return header, claims


def _agent_token(role: str) -> str:
    env_name = f"{role.upper()}_AGENT_TOKEN"
    token = os.environ.get(env_name, "")
    if token:
        return token

    appid_data = _diagrid_json("appid", "get", f"{role}-mcp-client")
    return (appid_data.get("status") or {}).get("apiToken") or ""


def _pg_select_employees() -> list[dict]:
    conn = psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "demo"),
        user=os.environ.get("UI_DB_USER", "postgres"),
        password=os.environ.get("UI_DB_PASSWORD", "demopassword"),
    )
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT e.id, e.name, e.email, "
                "       d.name AS department, "
                "       e.salary, "
                "       e.hired_on "
                "FROM employees e "
                "LEFT JOIN departments d ON e.department_id = d.id "
                "ORDER BY e.id"
            )
            rows = []
            for r in cur.fetchall():
                row = dict(r)
                if row.get("salary") is not None:
                    row["salary"] = float(row["salary"])
                if row.get("hired_on") is not None:
                    row["hired_on"] = row["hired_on"].isoformat()
                rows.append(row)
            return rows
    finally:
        conn.close()


# ─── API ──────────────────────────────────────────────────────────────────

@app.get("/api/health")
def health() -> dict:
    return {
        "ok": True,
        "project": PROJECT,
        "catalyst": {
            "apiKeyConfigured": bool(os.environ.get("DIAGRID_API_KEY")),
            "httpEndpoint": os.environ.get("DAPR_HTTP_ENDPOINT", ""),
            "grpcEndpoint": os.environ.get("DAPR_GRPC_ENDPOINT", ""),
            "agentTokensConfigured": bool(os.environ.get("HAS_AGENT_TOKENS")),
        },
    }


@app.get("/api/employees")
def employees() -> dict:
    rows = _pg_select_employees()
    return {"rows": rows}


@app.get("/api/identity")
def identity() -> dict:
    """Token prefixes + SHA-256 fingerprints for 3 agents + 1 MCP server."""
    out: dict[str, list[dict]] = {"agents": [], "servers": []}

    def _entry(appid: str, kind: str) -> dict:
        data = _diagrid_json("appid", "get", appid)
        token = (data.get("status", {}) or {}).get("apiToken", "") or ""
        prefix = token[:16] + "…" if token else "(no token)"
        fp = _fingerprint(token) if token else "sha256:(missing)"
        short_fp = (fp[:13] + "…" + fp[-6:]) if len(fp) > 24 else fp
        yaml = (
            f"appId: {appid}\n"
            f"project: {PROJECT}\n"
            f"type: {kind}\n"
            f"authentication:\n"
            f"  scheme: catalyst-bearer\n"
            f"  tokenPrefix: {prefix}\n"
            f"  fingerprint: {short_fp}"
        )
        return {
            "id": appid,
            "tokenPrefix": prefix,
            "fp": fp,
            "catalystUrl": f"https://catalyst.r1.diagrid.io/app-ids/details/{appid}",
            "yaml": yaml,
        }

    out["agents"]  = [_entry(a, "agent")  for a in AGENTS]
    out["servers"] = [_entry(s, "server") for s in SERVERS]
    return out


@app.get("/api/policy/configured")
def policy_configured() -> dict:
    """Read current ACL matrix from the MCPServer access policy.

    Returns the 3×3 matrix shape state.jsx uses + JWT middleware on/off.
    """
    matrix: dict[str, dict[str, bool]] = {
        role: {op: False for op in OP_TO_TOOLS} for role in ("analyst", "ops", "admin")
    }

    # Read the MCPServer access policy.
    # spec.rules[].callers[].appID and spec.rules[].grants[].names (capability=tools)
    try:
        data = _diagrid_json("mcpserver", "access", "get", "postgresql-mcp")
        rules = (data.get("spec", {}) or {}).get("rules", []) or []
        for rule in rules:
            callers = [c.get("appID") for c in (rule.get("callers") or [])]
            grants = rule.get("grants") or []
            allowed_tools: set[str] = set()
            for grant in grants:
                if grant.get("capability") == "tools":
                    names = grant.get("names") or []
                    allowed_tools.update(names)
            for caller in callers:
                for role in ("analyst", "ops", "admin"):
                    if caller in (f"{role}-mcp-client", "*"):
                        for op, tools in OP_TO_TOOLS.items():
                            if "*" in allowed_tools or allowed_tools & set(tools):
                                matrix[role][op] = True
    except HTTPException:
        pass  # Policy not yet set up — all-deny is correct default.

    # JWT middleware: postgresql-mcp always requires a bearer JWT (Dapr bearer
    # middleware applied once by ../setup.sh — not toggled). What's actually
    # toggled here is whether Diagrid itself is configured to fetch and
    # attach its own JWT: spec.endpoint.streamableHTTP.auth.oauth2 on the
    # MCPServer resource (see ../oauth2/setup.sh). Without it, nothing
    # attaches a JWT and every call 401s regardless of the ACL matrix above.
    jwt_on = False
    jwt_status = "absent"
    jwt_error = None
    try:
        data = _diagrid_json("mcpserver", "get", "postgresql-mcp")
        auth = (
            (data.get("spec", {}) or {})
            .get("endpoint", {})
            .get("streamableHTTP", {})
            .get("auth", {})
        )
        jwt_on = bool(auth.get("oauth2"))

        if jwt_on:
            status = (data.get("status", {}) or {}).get("status", "").lower()
            if status == "ready":
                jwt_status = "ready"
            elif status in ("updating", ""):
                jwt_status = "updating"
            else:
                jwt_status = "error"
                messages = (data.get("status", {}) or {}).get("messages") or []
                app_statuses = (data.get("status", {}) or {}).get("appIdStatus") or []
                for entry in app_statuses:
                    for msg in entry.get("messages") or []:
                        jwt_error = (msg.get("message") or "")[:240]
                        break
                    if jwt_error:
                        break
                if not jwt_error and messages:
                    jwt_error = (messages[0].get("message") or "")[:240]
    except HTTPException:
        jwt_status = "error"
        jwt_error = "MCPServer resource not found"

    return {
        "matrix": matrix,
        "jwtMiddleware": jwt_on,
        "jwtMiddlewareStatus": jwt_status,
        "jwtMiddlewareError": jwt_error,
    }


@app.post("/api/policy/apply")
def policy_apply(payload: dict = Body(...)) -> dict:
    """Apply a full editor matrix + JWT middleware state to Diagrid.

    Body shape:
        {
            "matrix": { "analyst": {"query": bool, "write": bool, "delete": bool}, ... },
            "jwtMiddleware": bool
        }

    Diffs vs. current state and runs the minimum set of
    `diagrid mcpserver access grant/revoke` commands to reach the target.
    """
    matrix = payload.get("matrix") or {}
    jwt_target = bool(payload.get("jwtMiddleware"))

    current = policy_configured()
    cur_matrix: dict = current["matrix"]
    cur_jwt: bool = current["jwtMiddleware"]

    changed_cells: list[str] = []

    for role in ("analyst", "ops", "admin"):
        for op in OP_TO_TOOLS:
            target = bool((matrix.get(role) or {}).get(op))
            if target != cur_matrix[role][op]:
                changed_cells.append(f"{role}:{op}")
                tools = ",".join(OP_TO_TOOLS[op])
                cmd_verb = "grant" if target else "revoke"
                cmd = [
                    "diagrid", "mcpserver", "access", cmd_verb, "postgresql-mcp",
                    "--caller", f"{role}-mcp-client",
                    "--allow-tools", tools,
                    "--project", PROJECT,
                ]
                if not target:
                    cmd += ["--approve"]
                _run_diagrid(cmd)

    jwt_changed = (jwt_target != cur_jwt)
    if jwt_changed:
        _apply_jwt_middleware(jwt_target)

    return {
        "changedCells": changed_cells,
        "jwtChanged": jwt_changed,
    }


def _apply_jwt_middleware(jwt_on: bool) -> None:
    """Add or remove Diagrid's own OAuth2 client-credentials auth on the
    MCPServer resource (see ../oauth2/setup.sh / teardown.sh). postgresql-mcp's
    bearer middleware always requires a JWT (baseline, set once by
    ../setup.sh) — this is what actually supplies one. Preserves the
    resource's current endpoint URL.
    """
    data = _diagrid_json("mcpserver", "get", "postgresql-mcp")
    current_url = (
        (data.get("spec", {}) or {})
        .get("endpoint", {})
        .get("streamableHTTP", {})
        .get("url", "")
    )
    if not current_url:
        raise HTTPException(status_code=502, detail="could not read postgresql-mcp's current endpoint URL")

    yaml_doc = (
        "apiVersion: dapr.io/v1alpha1\n"
        "kind: MCPServer\n"
        "metadata:\n"
        "  name: postgresql-mcp\n"
        "spec:\n"
        "  endpoint:\n"
        "    streamableHTTP:\n"
        f"      url: {current_url}\n"
    )
    if jwt_on:
        keycloak_public_url = os.environ.get("KEYCLOAK_PUBLIC_URL", "http://localhost:8080")
        keycloak_realm = os.environ.get("KEYCLOAK_REALM", "secure-mcp")
        keycloak_audience = os.environ.get("KEYCLOAK_AUDIENCE", "https://secure-mcp-demo/")
        client_secret = os.environ.get("CATALYST_PROXY_CLIENT_SECRET", "catalyst-proxy-secret")
        issuer = f"{keycloak_public_url}/realms/{keycloak_realm}/protocol/openid-connect/token"
        yaml_doc += (
            "      auth:\n"
            "        oauth2:\n"
            f"          issuer: {issuer}\n"
            f"          audience: {keycloak_audience}\n"
            "          clientID: catalyst-proxy\n"
            "          scopes: []\n"
            f"          clientSecret: {client_secret}\n"
        )
    # else: omitting `auth` entirely removes Diagrid's OAuth2 config —
    # nothing attaches a JWT, so every call 401s at the bearer middleware.

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(yaml_doc)
        path = f.name
    try:
        _run_diagrid(["diagrid", "apply", "--project", PROJECT, "-f", path])
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


@app.post("/api/jwt-preview")
def jwt_preview() -> dict:
    """Independently perform a client_credentials grant against Keycloak
    using the same catalyst-proxy client Diagrid itself uses server-side
    (see _apply_jwt_middleware above). This is NOT the token Diagrid
    attaches to any given /api/invoke call — Diagrid mints and attaches
    its own token internally, invisible to this backend. This endpoint
    exists purely to fetch and show an illustrative, real JWT for the same
    client identity — same issuer/audience/client, distinct token instance.
    """
    keycloak_public_url = os.environ.get("KEYCLOAK_PUBLIC_URL", "http://localhost:8080")
    keycloak_realm = os.environ.get("KEYCLOAK_REALM", "secure-mcp")
    client_secret = os.environ.get("CATALYST_PROXY_CLIENT_SECRET", "catalyst-proxy-secret")
    token_url = f"{keycloak_public_url}/realms/{keycloak_realm}/protocol/openid-connect/token"

    import httpx

    fetched_at = time.time()
    try:
        resp = httpx.post(
            token_url,
            data={
                "grant_type": "client_credentials",
                "client_id": "catalyst-proxy",
                "client_secret": client_secret,
            },
            timeout=10,
        )
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"could not reach Keycloak at {token_url}: {e}")

    if resp.status_code != 200:
        raise HTTPException(
            status_code=502,
            detail=f"Keycloak token endpoint returned {resp.status_code}: {resp.text[:300]}",
        )

    try:
        body = resp.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="Keycloak returned a non-JSON token response")

    token = body.get("access_token")
    if not token:
        raise HTTPException(status_code=502, detail="Keycloak response had no access_token field")

    try:
        header, claims = _decode_jwt_for_display(token)
    except (ValueError, json.JSONDecodeError) as e:
        raise HTTPException(status_code=502, detail=f"fetched token could not be decoded for display: {e}")

    return {
        "token": token,
        "header": header,
        "claims": claims,
        "fetchedAt": fetched_at,
        "expiresInSeconds": body.get("expires_in"),
    }


def _run_diagrid(cmd: list[str]) -> None:
    try:
        subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=20)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=502, detail=f"diagrid failed: {e.stderr.strip() or e.stdout.strip()}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="diagrid command timed out")


# ─── Invoke ───────────────────────────────────────────────────────────────

VERB_OF = {
    "query":  {"name": "query",           "args": "sql='SELECT * FROM employees ORDER BY id'"},
    "write":  {"name": "insert_employee", "args": 'name="Demo Target", email="demo-target@example.com"'},
    "delete": {"name": "delete_employee", "args": 'where name="Demo Target"'},
}


def _extract_status(exc: BaseException, _seen: set | None = None) -> int | None:
    if exc is None:
        return None
    if _seen is None:
        _seen = set()
    if id(exc) in _seen:
        return None
    _seen.add(id(exc))
    resp = getattr(exc, "response", None)
    code = getattr(resp, "status_code", None)
    if code:
        return code
    # Diagrid proxies a postgresql-mcp-side HTTP error (e.g. our own bearer
    # JWT rejection) as an MCP-protocol-level error, not a raw HTTP
    # response — surfaces as McpError("upstream HTTP 401: ...").
    match = re.search(r"HTTP (\d{3})", str(exc))
    if match:
        return int(match.group(1))
    for sub in getattr(exc, "exceptions", []) or []:
        s = _extract_status(sub, _seen)
        if s:
            return s
    for chained in (getattr(exc, "__cause__", None), getattr(exc, "__context__", None)):
        s = _extract_status(chained, _seen)
        if s:
            return s
    return None


def _lookup_demo_target_id() -> int | None:
    try:
        conn = psycopg2.connect(
            host=os.environ.get("DB_HOST", "localhost"),
            port=os.environ.get("DB_PORT", "5432"),
            dbname=os.environ.get("DB_NAME", "demo"),
            user=os.environ.get("UI_DB_USER", "postgres"),
            password=os.environ.get("UI_DB_PASSWORD", "demopassword"),
        )
        with conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id FROM employees WHERE name = 'Demo Target' ORDER BY id LIMIT 1")
                row = cur.fetchone()
                return row[0] if row else None
    finally:
        try:
            conn.close()
        except Exception:
            pass


@app.post("/api/invoke")
async def invoke(payload: dict = Body(...)) -> dict:
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    role = payload.get("role")
    op = payload.get("op")
    source = payload.get("source", "ui")

    if role not in ("analyst", "ops", "admin"):
        raise HTTPException(status_code=400, detail="invalid role")
    if op not in OP_TO_SERVER:
        raise HTTPException(status_code=400, detail="invalid op")

    catalyst_token = _agent_token(role)

    endpoint = os.environ.get("DAPR_HTTP_ENDPOINT") or ""
    if not endpoint:
        proj_data = _diagrid_project_get()
        endpoint = (((proj_data.get("status") or {}).get("endpoints") or {}).get("http") or {}).get("url") or ""

    if op == "query":
        tool, args = "query", {"sql": "SELECT * FROM employees ORDER BY id"}
    elif op == "write":
        tool = "insert_employee"
        email = f"demo-target-{time.time_ns()}@example.com"
        args = {
            "name": "Demo Target",
            "email": email,
            "department_id": 1,
            "salary": 1,
        }
    else:
        tool = "delete_employee"
        target_id = _lookup_demo_target_id()
        args = {"employee_id": target_id if target_id else 999_999_999}

    verb = VERB_OF[op]

    # postgresql-mcp always requires a bearer JWT, verified in its own
    # application code (servers/postgresql_mcp.py). It's Diagrid's own job to
    # attach one, via OAuth2 client-credentials configured on the MCPServer
    # resource (../oauth2/setup.sh) — this backend, like any caller, never
    # fetches or presents a JWT itself. Report the current global state for
    # the UI; a transient diagrid-CLI hiccup here shouldn't fail the whole
    # invoke, so default to "unknown" (reported as False) rather than 500.
    try:
        jwt_configured = bool(policy_configured().get("jwtMiddleware"))
    except HTTPException:
        jwt_configured = False

    headers = {"dapr-api-token": catalyst_token}

    url = f"{endpoint}/v1.0/diagrid/mcp/postgresql-mcp"

    t_iso = time.strftime("%H:%M:%S")
    t_start = time.time()

    kind = "ok"
    status = 200
    reason = None
    saw = True
    body = None

    try:
        async with streamablehttp_client(url, headers=headers) as (rd, wr, _):
            async with ClientSession(rd, wr) as session:
                await session.initialize()
                result = await session.call_tool(tool, args)
                body = " ".join(getattr(b, "text", "") for b in (result.content or []))
        await asyncio.sleep(0.05)
        hb = _recent_heartbeat("postgresql-mcp", tool)
        if hb:
            verb = {
                "name": tool,
                "args": ", ".join(f"{k}={v!r}" for k, v in (hb.get("args") or {}).items()),
            }
    except BaseException as e:
        st = _extract_status(e)
        status = st or 500
        saw = False
        if status == 401:
            kind = "jwt-deny"
            reason = "Diagrid's own OAuth2 auth isn't configured on the MCPServer resource yet"
        elif status == 403:
            kind = "acl-deny"
            reason = f"Diagrid ACL denied {role}-mcp-client tool: {tool}"
        else:
            kind = "acl-deny"
            reason = f"unexpected status {status}"

    return {
        "kind": kind,
        "status": status,
        "role": role,
        "op": op,
        "server": "postgresql-mcp",
        "jwt": jwt_configured,
        "source": source,
        "t": t_iso,
        "verb": verb,
        "sawTraffic": saw,
        "reason": reason,
        "durationMs": int((time.time() - t_start) * 1000),
        "body": body,
        "headersSent": _headers_sent(catalyst_token, None),
        "path": "/v1.0/diagrid/mcp/postgresql-mcp",
        "method": "POST",
    }


# ─── Spoofs (Phase 4) ─────────────────────────────────────────────────────
# Adversarial scenarios: fire real malicious HTTP against Diagrid and
# return the same result shape the Result panel renders.
#
# no-jwt-delete / bad-jwt-delete are gone: those simulated a CALLER
# presenting no/malformed JWT, which no longer means anything — Diagrid
# attaches its own JWT (or doesn't) via the MCPServer resource's OAuth2
# config, independent of what any caller does. There's nothing left for a
# caller to spoof at that layer.

SPOOF_KINDS = {
    "no-token", "forged-token", "analyst-on-delete",
}

_INIT_PAYLOAD = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "spoof", "version": "0"},
    },
}


@app.post("/api/spoof")
async def spoof(payload: dict = Body(...)) -> dict:
    import httpx
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    kind = payload.get("kind")
    if kind not in SPOOF_KINDS:
        raise HTTPException(status_code=400, detail=f"unknown spoof kind: {kind}")

    endpoint = os.environ.get("DAPR_HTTP_ENDPOINT") or ""
    if not endpoint:
        proj = _diagrid_project_get()
        endpoint = (((proj.get("status") or {}).get("endpoints") or {}).get("http") or {}).get("url") or ""

    url = f"{endpoint}/v1.0/diagrid/mcp/postgresql-mcp"

    headers: dict[str, str] = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    role = "external"
    op = "query"
    verb_label = "spoof"
    reason_template = ""

    t_iso = time.strftime("%H:%M:%S")
    t_start = time.time()

    # analyst-on-delete: use the actual MCP client to call delete_employee so
    # the tool-level ACL (403) is triggered — a raw session initialize alone
    # succeeds because the analyst has query access.
    if kind == "analyst-on-delete":
        analyst_token = _agent_token("analyst")
        role = "analyst"
        op = "delete"
        verb_label = "delete_employee"
        reason_template = "Diagrid ACL denied analyst-mcp-client tool: delete_employee"
        mcp_headers = {"dapr-api-token": analyst_token}

        status = 200
        result_kind = "ok"
        saw_traffic = True
        try:
            async with streamablehttp_client(url, headers=mcp_headers) as (rd, wr, _):
                async with ClientSession(rd, wr) as session:
                    await session.initialize()
                    await session.call_tool("delete_employee", {"employee_id": 999_999_999})
        except BaseException as e:
            st = _extract_status(e)
            status = st or 500
            saw_traffic = False
            result_kind = "acl-deny" if status == 403 else "edge-fail"

        return {
            "kind": result_kind,
            "status": status,
            "role": role,
            "op": op,
            "server": "postgresql-mcp",
            "jwt": False,
            "source": "external",
            "t": t_iso,
            "verb": {"name": verb_label, "args": "spoof: analyst-on-delete"},
            "sawTraffic": saw_traffic,
            "reason": reason_template,
            "durationMs": int((time.time() - t_start) * 1000),
            "attackKind": kind,
            "headersSent": _headers_sent(analyst_token, None),
            "path": "/v1.0/diagrid/mcp/postgresql-mcp",
            "method": "POST",
        }

    # Remaining spoofs use raw HTTP (they target Diagrid's edge, above
    # tool-level ACL). Note a 401 here means the *dapr-api-token* was
    # rejected at Diagrid's edge — a different 401 than the one postgresql-mcp's
    # bearer middleware returns when Diagrid's own OAuth2 auth isn't
    # configured (see ../oauth2/setup.sh / DEMO.md's step-up beat).
    if kind == "no-token":
        reason_template = "no bearer token presented"
    elif kind == "forged-token":
        headers["dapr-api-token"] = "this-token-was-never-issued-by-catalyst"
        reason_template = "bearer token signature invalid"

    try:
        resp = httpx.post(url, headers=headers, json=_INIT_PAYLOAD, timeout=10)
        status = resp.status_code
    except Exception:
        status = 0

    duration_ms = int((time.time() - t_start) * 1000)

    if status == 200:
        result_kind = "ok"
    elif status == 401:
        result_kind = "edge-fail"
    elif status == 403:
        result_kind = "acl-deny"
    else:
        result_kind = "edge-fail"

    saw_traffic = (status == 200)

    catalyst_token_sent = headers.get("dapr-api-token") or ""
    jwt_sent = ""
    auth = headers.get("Authorization") or ""
    if auth.startswith("Bearer "):
        jwt_sent = auth[len("Bearer "):]

    return {
        "kind": result_kind,
        "status": status,
        "role": role,
        "op": op,
        "server": "postgresql-mcp",
        "jwt": kind == "bad-jwt-delete",
        "source": "external",
        "t": t_iso,
        "verb": {"name": verb_label, "args": f"spoof: {kind}"},
        "sawTraffic": saw_traffic,
        "reason": reason_template,
        "durationMs": duration_ms,
        "attackKind": kind,
        "headersSent": _headers_sent(catalyst_token_sent, jwt_sent),
        "path": "/v1.0/diagrid/mcp/postgresql-mcp",
        "method": "POST",
    }


# ─── Event ingest + SSE stream (Phase 3) ─────────────────────────────────

@app.post("/api/events")
def ingest_event(evt: dict = Body(...)) -> dict:
    """MCP servers POST tool-invocation heartbeats here."""
    _publish_event(evt)
    return {"ok": True}


@app.get("/api/events/stream")
async def stream_events(request: Request) -> EventSourceResponse:
    """SSE channel — clients get the last few events on connect, then a
    push for every new event until the client disconnects."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=64)
    _subscribers.append(queue)

    recent = list(_event_log)[-20:]

    async def gen():
        try:
            for evt in recent:
                yield {"event": "tool_invoked", "data": json.dumps(evt)}
            while True:
                if await request.is_disconnected():
                    break
                try:
                    evt = await asyncio.wait_for(queue.get(), timeout=15.0)
                    yield {"event": "tool_invoked", "data": json.dumps(evt)}
                except asyncio.TimeoutError:
                    yield {"event": "ping", "data": ""}
        finally:
            try:
                _subscribers.remove(queue)
            except ValueError:
                pass

    return EventSourceResponse(gen())


# ─── Static UI mount ─────────────────────────────────────────────────────

app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="ui")
