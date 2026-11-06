"""Matrix probe: deterministic (no LLM) verification harness.

For the role in AGENT_ROLE, calls each tool via Diagrid's MCP proxy and
prints a ✓/✗ row. Diagrid enforces per-tool access (403 if denied); each
probe opens its own session so one denial doesn't abort the rest.

A 401 means Diagrid's own OAuth2 auth isn't configured on the MCPServer
resource (./oauth2/setup.sh) — the agent never handles a JWT itself.
"""

import asyncio
import os
import re

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

AGENT_ROLE = os.environ.get("AGENT_ROLE", "analyst")
DAPR_HTTP_ENDPOINT = os.environ["DAPR_HTTP_ENDPOINT"]
DAPR_API_TOKEN = os.environ["DAPR_API_TOKEN"]

MCP_URL = f"{DAPR_HTTP_ENDPOINT}/v1.0/diagrid/mcp/postgresql-mcp"

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

    # Diagrid proxies a postgresql-mcp-side HTTP error as an MCP-protocol
    # error, not a raw HTTP response — surfaces as McpError("upstream HTTP 401: ...").
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
    print(f"\n{BOLD}[{AGENT_ROLE}-mcp-client]{RESET} probing postgresql-mcp via Diagrid")
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
