"""Matrix probe agent.

For the role given in AGENT_ROLE, attempt one tool call for each operation
against the combined mcp-server via Catalyst's MCP proxy endpoint. Print a
✓/✗ row showing which tools the role's identity is allowed to invoke.

Catalyst enforces per-tool access: unauthorized tool calls are rejected with
403, and filtered out of tools/list. Each probe opens its own session so a
denial on one tool doesn't abort the others.

mcp-server also requires a valid Keycloak JWT on every call — checked in
its own application code (see servers/mcp_server.py) — but that JWT is
Catalyst's own, attached automatically via OAuth2 client-credentials
configured directly on the MCPServer resource (./oauth2/setup.sh). The
agent never sees or handles a JWT at all; a 401 here means Catalyst's own
OAuth2 auth isn't configured on the MCPServer resource, not anything the
agent did.

This is the deterministic verification harness — it does not use an LLM.
The LLM-driven `agent.py` is for live-demo scenes.
"""

import asyncio
import os
import re

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

AGENT_ROLE = os.environ.get("AGENT_ROLE", "analyst")
DAPR_HTTP_ENDPOINT = os.environ["DAPR_HTTP_ENDPOINT"]
DAPR_API_TOKEN = os.environ["DAPR_API_TOKEN"]

MCP_URL = f"{DAPR_HTTP_ENDPOINT}/v1.0/diagrid/mcp/mcp-server"

# One probe per operation. Args chosen to be no-op friendly so repeated
# runs don't mutate state in surprising ways (update/delete of id 999999).
PROBES = [
    ("query",           {"sql": "SELECT 1"}),
    ("update_salary",   {"employee_id": 999999, "new_salary": 100000}),
    ("delete_employee", {"employee_id": 999999}),
]


def _why(exc, _seen=None):
    """Best-effort one-line summary of why a probe failed."""
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

    # Catalyst proxies an mcp-server-side HTTP error (e.g. our own bearer
    # JWT rejection) as an MCP-protocol-level error, not a raw HTTP
    # response — surfaces here as McpError("upstream HTTP 401: ...").
    match = re.search(r"HTTP (\d{3})", str(exc))
    if match:
        return f"HTTP {match.group(1)}"

    for sub in getattr(exc, "exceptions", []):
        found = _why(sub, _seen)
        if found:
            return found

    for chained in (getattr(exc, "__cause__", None), getattr(exc, "__context__", None)):
        found = _why(chained, _seen)
        if found:
            return found

    return None


async def probe_one(tool: str, args: dict) -> tuple[bool, str]:
    headers = {"dapr-api-token": DAPR_API_TOKEN}
    try:
        async with streamablehttp_client(MCP_URL, headers=headers) as (read, write, _):
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
    print(f"\n{BOLD}[{AGENT_ROLE}-agent]{RESET} probing mcp-server via Catalyst")
    rows = []
    for tool, args in PROBES:
        ok, why = await probe_one(tool, args)
        mark = f"{GREEN}✓{RESET}" if ok else f"{RED}✗ ({why}){RESET}"
        rows.append((tool, mark))

    width = max(len(r[0]) for r in rows)
    for tool, mark in rows:
        print(f"  {tool:<{width}}  {mark}")


if __name__ == "__main__":
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
