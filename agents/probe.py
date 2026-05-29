"""Matrix probe agent.

For the role given in AGENT_ROLE, attempt one tool call against each of the
three per-op MCP servers via Catalyst. Print a ✓/✗ row showing which
operations the role's identity is allowed to invoke.

This is the deterministic verification harness — it does not use an LLM.
The LLM-driven `agent.py` is for live-demo scenes where the agent decides
what to call.
"""

import asyncio
import os
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

AGENT_ROLE = os.environ.get("AGENT_ROLE", "analyst")
DAPR_HTTP_ENDPOINT = os.environ["DAPR_HTTP_ENDPOINT"]
DAPR_API_TOKEN = os.environ["DAPR_API_TOKEN"]

# Optional OIDC: when all of these are set, the probe will fetch a JWT from
# Keycloak via client_credentials and include it as Authorization: Bearer on
# every MCP call. Required when the bearer middleware is active on a server.
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM")
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET")
KEYCLOAK_AUDIENCE = os.environ.get("KEYCLOAK_AUDIENCE")


def _fetch_jwt():
    """Fetch a JWT from Keycloak via client_credentials. None if env not set."""
    if not all([KEYCLOAK_URL, KEYCLOAK_REALM, KEYCLOAK_CLIENT_ID, KEYCLOAK_CLIENT_SECRET]):
        return None
    token_url = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"
    resp = httpx.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": KEYCLOAK_CLIENT_ID,
            "client_secret": KEYCLOAK_CLIENT_SECRET,
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


_JWT = _fetch_jwt()

# One probe per per-op server. Args chosen to be no-op friendly so repeated
# runs don't mutate state in surprising ways (update/delete of id 999999).
PROBES = [
    ("mcp-db-query",  "query",          {"sql": "SELECT 1"}),
    ("mcp-db-write",  "update_salary",  {"employee_id": 999999, "new_salary": 100000}),
    ("mcp-db-delete",    "delete_employee", {"employee_id": 999999}),
]


def _why(exc, _seen=None):
    """Best-effort one-line summary of why a probe failed.

    Walks the full exception tree — direct exception, nested
    BaseExceptionGroups, __cause__, and __context__ — looking for an
    httpx response with a status code.
    """
    if exc is None:
        return None
    if _seen is None:
        _seen = set()
    if id(exc) in _seen:
        return None
    _seen.add(id(exc))

    resp = getattr(exc, "response", None)
    status = getattr(resp, "status_code", None)
    if status:
        return f"HTTP {status}"

    for sub in getattr(exc, "exceptions", []):
        found = _why(sub, _seen)
        if found:
            return found

    for chained in (getattr(exc, "__cause__", None), getattr(exc, "__context__", None)):
        found = _why(chained, _seen)
        if found:
            return found

    return None


async def probe_one(appid: str, tool: str, args: dict) -> tuple[bool, str]:
    url = f"{DAPR_HTTP_ENDPOINT}/v1.0/invoke/{appid}/method/mcp"
    headers = {"dapr-api-token": DAPR_API_TOKEN}
    if _JWT:
        headers["Authorization"] = f"Bearer {_JWT}"
    try:
        async with streamablehttp_client(url, headers=headers) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                await session.call_tool(tool, args)
                return True, ""
    except BaseException as e:
        if isinstance(e, (KeyboardInterrupt, SystemExit)):
            raise
        return False, (_why(e) or type(e).__name__)


GREEN = "\033[32m"
RED = "\033[31m"
BOLD = "\033[1m"
RESET = "\033[0m"


async def main():
    jwt_note = " (with Keycloak JWT)" if _JWT else ""
    print(f"\n{BOLD}[{AGENT_ROLE}-agent]{RESET} probing 4 per-op MCP servers via Catalyst{jwt_note}")
    rows = []
    for appid, tool, args in PROBES:
        ok, why = await probe_one(appid, tool, args)
        mark = f"{GREEN}✓{RESET}" if ok else f"{RED}✗ ({why}){RESET}"
        rows.append((appid, tool, mark))

    width_a = max(len(r[0]) for r in rows)
    width_b = max(len(r[1]) for r in rows)
    for a, b, m in rows:
        print(f"  {a:<{width_a}}  {b:<{width_b}}  {m}")


if __name__ == "__main__":
    # Set the asyncgen exception handler the way the LLM agent does — keeps
    # 403 messages legible if MCPStreamableHTTPTool's cleanup surfaces them.
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(main())
    finally:
        try:
            loop.run_until_complete(loop.shutdown_asyncgens())
        except BaseException:
            pass
        loop.close()
