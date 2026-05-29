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
import hashlib
import json
import os
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

AGENTS = ["analyst-agent", "ops-agent", "admin-agent"]
SERVERS = ["mcp-db-query", "mcp-db-write", "mcp-db-delete"]

OP_TO_SERVER = {
    "query":  "mcp-db-query",
    "write":  "mcp-db-write",
    "delete": "mcp-db-delete",
}
OP_TO_CONFIG = {
    "query":  "db-query",
    "write":  "db-write",
    "delete": "db-delete",
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
    """Find the most recent heartbeat for (server, tool) within a window.
    Used by /api/invoke to enrich its response with what the server saw."""
    cutoff = time.time() - within_seconds
    for evt in reversed(_event_log):
        if evt.get("ts", 0) < cutoff:
            break
        if evt.get("server") == server and evt.get("tool") == tool:
            return evt
    return None


# ─── helpers ──────────────────────────────────────────────────────────────

def _diagrid_json(*args: str) -> dict:
    """Run a diagrid CLI command and parse its JSON output."""
    cmd = ["diagrid", *args, "--project", PROJECT, "--output", "json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
    except FileNotFoundError:
        raise HTTPException(status_code=502, detail="diagrid CLI not found in UI backend image")
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=502, detail=f"diagrid command failed: {e.stderr.strip()}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="diagrid command timed out")
    return json.loads(out.stdout)


def _diagrid_project_get() -> dict:
    """`diagrid project get` takes project as positional, not a flag."""
    cmd = ["diagrid", "project", "get", PROJECT, "--output", "json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
    except FileNotFoundError:
        raise HTTPException(status_code=502, detail="diagrid CLI not found in UI backend image")
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=502, detail=f"diagrid project get failed: {e.stderr.strip()}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="diagrid project get timed out")
    return json.loads(out.stdout)


def _fingerprint(token: str) -> str:
    return "sha256:" + hashlib.sha256(token.encode()).hexdigest()


def _mask_dapr_token(t: str, prefix: int = 16, suffix: int = 8) -> str:
    """Mask a Catalyst dapr-api-token for UI display: keep prefix + suffix,
    ellipsis the middle. Tokens look like
    `diagrid://v1/<org>/<proj>/<appid>/<uuid>` so the prefix tells you it's
    a real Catalyst token and the suffix is enough to disambiguate roles."""
    if not t:
        return ""
    if len(t) <= prefix + suffix + 1:
        return t
    return f"{t[:prefix]}…{t[-suffix:]}"


def _mask_jwt(t: str, prefix: int = 24) -> str:
    """JWTs are header.payload.signature, base64url. The header start is
    recognizable (eyJhbGc...) and signals 'this is a JWT'; we don't want
    to leak the payload claims so we cut after the header."""
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


def _agent_token(role: str) -> str:
    env_name = f"{role.upper()}_AGENT_TOKEN"
    token = os.environ.get(env_name, "")
    if token:
        return token

    appid_data = _diagrid_json("appid", "get", f"{role}-agent")
    return (appid_data.get("status") or {}).get("apiToken") or ""


def _pg_select_employees() -> list[dict]:
    """Read the employees table directly, joined with departments so the
    UI can render the readable department name. Uses postgres superuser
    so the UI can read regardless of which per-op DB role is exercised."""
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
                # Decimal + date aren't JSON-native — coerce for the wire.
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
    """Token prefixes + SHA-256 fingerprints for 3 agents + 4 per-op servers.

    Matches the shape state.jsx expects in its IDENTITY constant.
    """
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
    """Read current ACL matrix from Catalyst.

    Returns the 3x3 matrix shape state.jsx uses + JWT middleware on/off.
    """
    matrix: dict[str, dict[str, bool]] = {
        role: {op: False for op in OP_TO_CONFIG} for role in ("analyst", "ops", "admin")
    }

    for op, cfg_name in OP_TO_CONFIG.items():
        try:
            data = _diagrid_json("configuration", "get", cfg_name)
        except HTTPException:
            # Configuration might not exist yet (pre-setup). Treat as all-deny.
            continue
        ac = (data.get("spec", {}) or {}).get("accessControl", {}) or {}
        policies = ac.get("policies", []) or []
        for entry in policies:
            who = entry.get("appId", "")
            # appId comes as "analyst-agent"; matrix keys are "analyst"
            for role in matrix:
                if who == f"{role}-agent":
                    matrix[role][op] = (entry.get("defaultAction") == "allow")

    # JWT middleware on mcp-db-delete: the bearer middleware is wired into the
    # db-delete Configuration under spec.appHttpPipeline.handlers as a
    # middleware.http.bearer handler.
    jwt_on = False
    try:
        data = _diagrid_json("configuration", "get", "db-delete")
        pipeline = (data.get("spec", {}) or {}).get("appHttpPipeline", {}) or {}
        handlers = pipeline.get("handlers", []) or []
        jwt_on = any(
            (h.get("type", "") or "").endswith(".bearer")
            or "bearer" in (h.get("name", "") or "").lower()
            for h in handlers
        )
    except HTTPException:
        jwt_on = False

    # Even when the pipeline is wired, the bearer Component itself can
    # silently fail-open if it can't fetch JWKS (ngrok down, Keycloak
    # unreachable, etc.). Surface that state so the UI can warn.
    jwt_status = "absent"
    jwt_error = None
    if jwt_on:
        try:
            comp = _diagrid_json("component", "get", "bearer")
            appid_statuses = ((comp.get("status") or {}).get("appidStatus") or [])
            for entry in appid_statuses:
                if entry.get("appId") == "mcp-db-delete":
                    raw_status = (entry.get("status") or "").lower()
                    if raw_status == "ready":
                        jwt_status = "ready"
                    else:
                        jwt_status = "error"
                        msgs = entry.get("messages") or []
                        if msgs:
                            jwt_error = (msgs[0].get("message") or "")[:240]
                    break
        except HTTPException:
            jwt_status = "error"
            jwt_error = "bearer Component not found"

    return {
        "matrix": matrix,
        "jwtMiddleware": jwt_on,
        "jwtMiddlewareStatus": jwt_status,        # "ready" | "error" | "absent"
        "jwtMiddlewareError": jwt_error,
    }


@app.post("/api/policy/apply")
def policy_apply(payload: dict = Body(...)) -> dict:
    """Apply a full editor matrix + JWT middleware state to Catalyst.

    Body shape:
        {
            "matrix": { "analyst": {"query": bool, "write": bool, "delete": bool}, ... },
            "jwtMiddleware": bool
        }

    Computes the diff vs. current configured state and runs the minimum
    set of diagrid commands to reach the target. Returns the list of
    changed cell keys ("role:op") plus whether JWT middleware moved.
    """
    matrix = payload.get("matrix") or {}
    jwt_target = bool(payload.get("jwtMiddleware"))

    # Read current state so we only push what changed
    current = policy_configured()
    cur_matrix: dict = current["matrix"]
    cur_jwt: bool = current["jwtMiddleware"]

    changed_cells: list[str] = []
    changed_cols: set[str] = set()

    for role in ("analyst", "ops", "admin"):
        for op in OP_TO_CONFIG:
            target = bool((matrix.get(role) or {}).get(op))
            if target != cur_matrix[role][op]:
                changed_cells.append(f"{role}:{op}")
                changed_cols.add(op)

    jwt_changed = (jwt_target != cur_jwt)
    if jwt_changed:
        changed_cols.add("delete")  # JWT lives on db-delete

    # Apply per affected column
    for op in changed_cols:
        cfg_name = OP_TO_CONFIG[op]
        if op == "delete":
            _apply_db_delete(matrix, jwt_target)
        else:
            _apply_imperative(cfg_name, op, matrix)

    return {
        "changedCells": changed_cells,
        "jwtChanged": jwt_changed,
    }


def _apply_imperative(cfg_name: str, op: str, matrix: dict) -> None:
    """Run `diagrid configuration update` for db-query / db-write."""
    flags = []
    for role in ("analyst", "ops", "admin"):
        action = "allow" if (matrix.get(role) or {}).get(op) else "deny"
        flags.extend(["--policy", f"{role}-agent:{action}"])
    cmd = ["diagrid", "configuration", "update", cfg_name,
           "--project", PROJECT, "--default-action", "deny", *flags]
    _run_diagrid(cmd)


def _apply_db_delete(matrix: dict, jwt_on: bool) -> None:
    """Declarative apply for db-delete so we can include the appHttpPipeline
    (JWT bearer middleware) in the same write."""
    policies_yaml = []
    for role in ("analyst", "ops", "admin"):
        action = "allow" if (matrix.get(role) or {}).get("delete") else "deny"
        policies_yaml.append(f"      - appId: {role}-agent\n        defaultAction: {action}")

    yaml_doc = (
        "apiVersion: dapr.io/v1alpha1\n"
        "kind: Configuration\n"
        "metadata:\n"
        "  name: db-delete\n"
        "spec:\n"
        "  accessControl:\n"
        "    defaultAction: deny\n"
        "    policies:\n"
        + "\n".join(policies_yaml) + "\n"
    )
    if jwt_on:
        yaml_doc += (
            "  appHttpPipeline:\n"
            "    handlers:\n"
            "      - name: bearer\n"
            "        type: middleware.http.bearer\n"
        )

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


def _run_diagrid(cmd: list[str]) -> None:
    try:
        subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=20)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=502, detail=f"diagrid failed: {e.stderr.strip() or e.stdout.strip()}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="diagrid command timed out")


# ─── Invoke ───────────────────────────────────────────────────────────────

VERB_OF = {
    "query":  {"name": "list_employees",  "args": "limit=100"},
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


def _fetch_keycloak_jwt() -> str:
    import httpx
    missing = [
        v for v in ("KEYCLOAK_URL", "KEYCLOAK_REALM", "KEYCLOAK_CLIENT_ID", "KEYCLOAK_CLIENT_SECRET")
        if not os.environ.get(v)
    ]
    if missing:
        raise RuntimeError(
            f"UI backend missing env vars: {', '.join(missing)} "
            f"(export them before launching ./ui_backend/run.sh)"
        )
    url = (
        f"{os.environ['KEYCLOAK_URL']}/realms/{os.environ['KEYCLOAK_REALM']}"
        f"/protocol/openid-connect/token"
    )
    resp = httpx.post(
        url,
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["KEYCLOAK_CLIENT_ID"],
            "client_secret": os.environ["KEYCLOAK_CLIENT_SECRET"],
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


@app.post("/api/invoke")
async def invoke(payload: dict = Body(...)) -> dict:
    import time
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    role = payload.get("role")
    op = payload.get("op")
    jwt_presented = bool(payload.get("jwtPresented"))
    source = payload.get("source", "ui")

    if role not in ("analyst", "ops", "admin"):
        raise HTTPException(status_code=400, detail="invalid role")
    if op not in OP_TO_SERVER:
        raise HTTPException(status_code=400, detail="invalid op")

    # Identity + endpoint
    catalyst_token = _agent_token(role)

    # Prefer the standard Dapr SDK env var (set by the chart from
    # catalyst.httpEndpoint). Fall back to a CLI call so the local-dev
    # path keeps working without any extra setup.
    endpoint = os.environ.get("DAPR_HTTP_ENDPOINT") or ""
    if not endpoint:
        proj_data = _diagrid_project_get()
        endpoint = (((proj_data.get("status") or {}).get("endpoints") or {}).get("http") or {}).get("url") or ""

    # Op → tool + args
    server = OP_TO_SERVER[op]
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
        # If Demo Target doesn't exist, send a sentinel id so the request
        # still traverses every gate before the SQL becomes a no-op.
        args = {"employee_id": target_id if target_id else 999_999_999}

    verb = VERB_OF[op]

    # Optional JWT
    jwt_token = None
    jwt_error = None
    if jwt_presented:
        try:
            jwt_token = _fetch_keycloak_jwt()
        except Exception as e:
            jwt_error = str(e)[:120]

    headers = {"dapr-api-token": catalyst_token}
    if jwt_token:
        headers["Authorization"] = f"Bearer {jwt_token}"

    url = f"{endpoint}/v1.0/invoke/{server}/method/mcp"

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
        # Brief pause so the server's fire-and-forget heartbeat lands in
        # the event log before we read it back to enrich the response.
        await asyncio.sleep(0.05)
        hb = _recent_heartbeat(server, tool)
        if hb:
            # Use the actual args the server saw — more honest than what we sent
            verb = {
                "name": tool,
                "args": ", ".join(f"{k}={v!r}" for k, v in (hb.get("args") or {}).items()),
            }
    except BaseException as e:
        st = _extract_status(e)
        status = st or 500
        saw = False
        if status == 401:
            # 401 from a UI button always comes from the JWT layer (we
            # always send a valid Catalyst token). Edge-fail is reserved
            # for terminal-driven spoofs in Phase 4.
            kind = "jwt-deny"
            reason = jwt_error or "JWT missing / invalid / wrong audience"
        elif status == 403:
            kind = "acl-deny"
            reason = f"Catalyst ACL denied {role}-agent on {server}"
        else:
            kind = "acl-deny"
            reason = f"unexpected status {status}"

    return {
        "kind": kind,
        "status": status,
        "role": role,
        "op": op,
        "server": server,
        "jwt": jwt_presented,
        "source": source,
        "t": t_iso,
        "verb": verb,
        "sawTraffic": saw,
        "reason": reason,
        "durationMs": int((time.time() - t_start) * 1000),
        "body": body,
        "headersSent": _headers_sent(catalyst_token, jwt_token),
        "path": f"/v1.0/invoke/{server}/method/mcp",
        "method": "POST",
    }


# ─── Spoofs (Phase 4) ─────────────────────────────────────────────────────
# Adversarial scenarios row: fire real malicious HTTP against Catalyst and
# return the same result shape the Result panel renders. Uses httpx
# directly (not the MCP client) so we can construct exactly the wrong
# headers without the client adding defaults.

SPOOF_KINDS = {
    "no-token", "forged-token", "analyst-on-delete",
    "no-jwt-delete", "bad-jwt-delete",
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


def _mint_bad_jwt() -> str:
    import base64
    header = base64.urlsafe_b64encode(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()).rstrip(b"=").decode()
    payload = base64.urlsafe_b64encode(json.dumps({
        "iss": "http://localhost:8080/realms/secure-mcp",
        "aud": "https://different-api/",
        "exp": int(time.time()) + 3600,
        "iat": int(time.time()),
        "sub": "spoofer",
    }).encode()).rstrip(b"=").decode()
    sig = base64.urlsafe_b64encode(b"fake-signature").rstrip(b"=").decode()
    return f"{header}.{payload}.{sig}"


@app.post("/api/spoof")
def spoof(payload: dict = Body(...)) -> dict:
    import httpx

    kind = payload.get("kind")
    if kind not in SPOOF_KINDS:
        raise HTTPException(status_code=400, detail=f"unknown spoof kind: {kind}")

    endpoint = os.environ.get("DAPR_HTTP_ENDPOINT") or ""
    if not endpoint:
        proj = _diagrid_project_get()
        endpoint = (((proj.get("status") or {}).get("endpoints") or {}).get("http") or {}).get("url") or ""

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    target_server = "mcp-db-query"   # default for no-token / forged-token
    role = "external"
    op = "query"
    verb_label = "spoof"

    if kind == "no-token":
        # POST with no dapr-api-token at all
        reason_template = "no bearer token presented"
    elif kind == "forged-token":
        headers["dapr-api-token"] = "this-token-was-never-issued-by-catalyst"
        reason_template = "bearer token signature invalid"
    elif kind == "analyst-on-delete":
        # Real analyst token, against mcp-db-delete → ACL denies
        headers["dapr-api-token"] = _agent_token("analyst")
        target_server = "mcp-db-delete"
        op = "delete"
        verb_label = "delete_employee"
        reason_template = "Catalyst ACL denied analyst-agent on mcp-db-delete"
    elif kind == "no-jwt-delete":
        # Real admin token, no JWT header, against mcp-db-delete → middleware denies
        headers["dapr-api-token"] = _agent_token("admin")
        target_server = "mcp-db-delete"
        op = "delete"
        verb_label = "delete_employee"
        reason_template = "JWT middleware: no Authorization header"
    elif kind == "bad-jwt-delete":
        # Real admin token + bogus JWT (wrong aud) → middleware denies
        headers["dapr-api-token"] = _agent_token("admin")
        headers["Authorization"] = f"Bearer {_mint_bad_jwt()}"
        target_server = "mcp-db-delete"
        op = "delete"
        verb_label = "delete_employee"
        reason_template = "JWT middleware: signature / audience invalid"

    url = f"{endpoint}/v1.0/invoke/{target_server}/method/mcp"
    t_iso = time.strftime("%H:%M:%S")
    t_start = time.time()

    try:
        resp = httpx.post(url, headers=headers, json=_INIT_PAYLOAD, timeout=10)
        status = resp.status_code
    except Exception as e:
        status = 0

    duration_ms = int((time.time() - t_start) * 1000)

    if status == 200:
        result_kind = "ok"
    elif status == 401 and target_server == "mcp-db-delete" and "Authorization" in headers and kind == "bad-jwt-delete":
        result_kind = "jwt-deny"
    elif status == 401 and target_server == "mcp-db-delete" and "Authorization" not in headers and kind == "no-jwt-delete":
        result_kind = "jwt-deny"
    elif status == 401:
        result_kind = "edge-fail"
    elif status == 403:
        result_kind = "acl-deny"
    else:
        result_kind = "edge-fail"

    saw_traffic = (status == 200)

    # Reconstruct the (already-masked) view of what we sent so the Result
    # panel can show the audience what auth shape went over the wire.
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
        "server": target_server,
        "jwt": kind == "bad-jwt-delete",
        "source": "external",
        "t": t_iso,
        "verb": {"name": verb_label, "args": f"spoof: {kind}"},
        "sawTraffic": saw_traffic,
        "reason": reason_template,
        "durationMs": duration_ms,
        "attackKind": kind,
        "headersSent": _headers_sent(catalyst_token_sent, jwt_sent),
        "path": f"/v1.0/invoke/{target_server}/method/mcp",
        "method": "POST",
    }


# ─── Event ingest + SSE stream (Phase 3) ─────────────────────────────────

@app.post("/api/events")
def ingest_event(evt: dict = Body(...)) -> dict:
    """MCP servers POST tool-invocation heartbeats here.
    Best-effort: we never fail an MCP call because the UI is offline."""
    _publish_event(evt)
    return {"ok": True}


@app.get("/api/events/stream")
async def stream_events(request: Request) -> EventSourceResponse:
    """SSE channel — clients get the last few events on connect, then a
    push for every new event until the client disconnects."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=64)
    _subscribers.append(queue)

    # Replay the last 20 events so a reload doesn't lose context.
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
                    # SSE keepalive — comment lines are ignored by EventSource
                    yield {"event": "ping", "data": ""}
        finally:
            try:
                _subscribers.remove(queue)
            except ValueError:
                pass

    return EventSourceResponse(gen())


# ─── Static UI mount ─────────────────────────────────────────────────────

# The UI is served as-is at /. Babel-in-browser handles JSX transform.
# `html=True` makes StaticFiles serve index.html when the root path is requested.
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="ui")
