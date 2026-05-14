"""Smoke test for db_query.py. Runs the MCP handshake then calls the tool."""

import asyncio

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def main():
    async with streamablehttp_client("http://localhost:8001/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            print("Tools:", [t.name for t in tools.tools])

            result = await session.call_tool(
                "query",
                {"sql": "SELECT name, salary FROM employees ORDER BY salary DESC LIMIT 3"},
            )
            for block in result.content:
                print(getattr(block, "text", block))


if __name__ == "__main__":
    asyncio.run(main())
