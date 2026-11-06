"""Parameterized MCP agent.

Reads AGENT_ROLE from env and calls the combined postgresql-mcp through
Diagrid's MCP proxy endpoint. The asyncgen exception handler captures
HTTP errors that surface during MCPStreamableHTTPTool shutdown.
"""

import asyncio
import os
import sys

import httpx
from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatClient

AGENT_ROLE = os.environ.get("AGENT_ROLE", "analyst")
DAPR_HTTP_ENDPOINT = os.environ["DAPR_HTTP_ENDPOINT"]
DAPR_API_TOKEN = os.environ["DAPR_API_TOKEN"]

MCP_URL = f"{DAPR_HTTP_ENDPOINT}/v1.0/diagrid/mcp/postgresql-mcp"

_connection_error = None


def _extract_http_error(exc):
    if exc is None:
        return None
    if hasattr(exc, "response") and hasattr(exc.response, "status_code"):
        return str(exc).partition(" for url")[0]
    for sub in getattr(exc, "exceptions", []):
        result = _extract_http_error(sub)
        if result:
            return result
    return None


def _exception_handler(loop, context):
    global _connection_error
    if "asyncgen" in context:
        http_err = _extract_http_error(context.get("exception"))
        if http_err:
            _connection_error = http_err
        return
    loop.default_exception_handler(context)


async def run():
    try:
        http_client = httpx.AsyncClient(headers={"dapr-api-token": DAPR_API_TOKEN})
        async with MCPStreamableHTTPTool(
            name="postgresql-mcp",
            url=MCP_URL,
            http_client=http_client,
        ) as mcp_tool:
            agent = Agent(
                OpenAIChatClient(model="gpt-4o-mini"),
                name=f"{AGENT_ROLE}-mcp-client",
                tools=mcp_tool,
            )

            print(f"[{AGENT_ROLE}] Asking the database for the top 3 salaries...")
            result = await agent.run(
                "Use the query tool to run: "
                "SELECT name, salary FROM employees ORDER BY salary DESC LIMIT 3"
            )
            print(f"[{AGENT_ROLE}] Result: {result.text}")
            return None

    except BaseException as e:
        if isinstance(e, (KeyboardInterrupt, SystemExit)):
            raise
        return e


if __name__ == "__main__":
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.set_exception_handler(_exception_handler)

    error = loop.run_until_complete(run())

    try:
        loop.run_until_complete(loop.shutdown_asyncgens())
        loop.run_until_complete(loop.shutdown_default_executor())
    except BaseException:
        pass
    finally:
        loop.close()
        asyncio.set_event_loop(None)

    if error is not None:
        msg = _connection_error or str(error) or type(error).__name__
        print(f"[{AGENT_ROLE}] Access denied or connection error: {msg}", file=sys.stderr)
        sys.exit(1)
