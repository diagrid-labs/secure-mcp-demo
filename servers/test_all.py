"""Standalone smoke tests for all four per-op MCP servers.

Hits each server directly on localhost (no Catalyst). Each server must be
running in its own terminal before this is invoked.
"""

import asyncio

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


SERVERS = [
    ("mcp-db-query",  "http://localhost:8001/mcp", "query",
        {"sql": "SELECT name FROM employees LIMIT 1"}),
    ("mcp-db-schema", "http://localhost:8002/mcp", "list_tables", {}),
    ("mcp-db-write",  "http://localhost:8003/mcp", "update_salary",
        {"employee_id": 1, "new_salary": 145000}),
    ("mcp-db-ddl",    "http://localhost:8004/mcp", "delete_employee",
        {"employee_id": 999999}),  # non-existent id; safe no-op
]


async def smoke(name: str, url: str, tool: str, args: dict) -> None:
    async with streamablehttp_client(url) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool, args)
            text = " ".join(getattr(b, "text", str(b)) for b in result.content)
            print(f"  {name:<16} {tool}({args}) → {text[:80]}")


async def main():
    for srv in SERVERS:
        try:
            await smoke(*srv)
        except Exception as e:
            print(f"  {srv[0]:<16} FAILED: {e}")


if __name__ == "__main__":
    asyncio.run(main())
