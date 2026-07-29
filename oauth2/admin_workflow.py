"""Admin destructive MCP call helper, parameterized by action.

Usage:
  uv run python oauth2/admin_workflow.py insert
      → inserts a "Demo Target" employee, prints "id=N" on success

  uv run python oauth2/admin_workflow.py delete <employee_id>
      → deletes the employee with that id

Both calls go through Catalyst via the MCPServer proxy endpoint and require
admin's Catalyst API token. mcp-server also requires a valid Keycloak JWT on
every call — checked in its own application code (see
../servers/mcp_server.py) — but that JWT is Catalyst's own, attached
automatically via OAuth2 client-credentials configured on the MCPServer
resource (./setup.sh). Nothing here handles a JWT directly.

Env vars expected:
  DAPR_HTTP_ENDPOINT, DAPR_API_TOKEN
"""

import argparse
import asyncio
import os
import re
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

DAPR_HTTP_ENDPOINT = os.environ["DAPR_HTTP_ENDPOINT"]
DAPR_API_TOKEN = os.environ["DAPR_API_TOKEN"]

MCP_URL = f"{DAPR_HTTP_ENDPOINT}/v1.0/diagrid/mcp/mcp-server"


async def _call(tool: str, args: dict) -> str:
    headers = {"dapr-api-token": DAPR_API_TOKEN}
    async with streamablehttp_client(MCP_URL, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool, args)
            return " ".join(getattr(b, "text", "") for b in result.content)


async def insert() -> int:
    resp = await _call(
        "insert_employee",
        {
            "name": "Demo Target",
            "email": "demo-target@example.com",
            "department_id": 1,
            "salary": 1,
        },
    )
    match = re.search(r"id=(\d+)", resp)
    if not match:
        print(f"ERROR: couldn't parse new id from response: {resp}", file=sys.stderr)
        sys.exit(1)
    new_id = int(match.group(1))
    print(f"id={new_id}")
    return new_id


async def delete(employee_id: int) -> None:
    resp = await _call("delete_employee", {"employee_id": employee_id})
    print(resp)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("insert")
    delete_parser = sub.add_parser("delete")
    delete_parser.add_argument("employee_id", type=int)
    args = parser.parse_args()

    if args.action == "insert":
        asyncio.run(insert())
    else:
        asyncio.run(delete(args.employee_id))


if __name__ == "__main__":
    main()
