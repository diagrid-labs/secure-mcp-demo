"""Admin destructive MCP call helper.

Usage:
  uv run python oauth2/admin_workflow.py insert            → prints "id=N"
  uv run python oauth2/admin_workflow.py delete <employee_id>

Calls go through Catalyst's MCP proxy with admin's Catalyst API token
(env: DAPR_HTTP_ENDPOINT, DAPR_API_TOKEN). Never handles a JWT directly —
that's Catalyst's own, attached via oauth2/setup.sh.
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

MCP_URL = f"{DAPR_HTTP_ENDPOINT}/v1.0/diagrid/mcp/postgresql-mcp"


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
