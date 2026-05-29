import os

import httpx
import psycopg2


def get_connection():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "demo"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


# MCP servers run on the host via `diagrid dev run` (uv subprocesses),
# so localhost reaches the UI backend directly.
UI_BACKEND_URL = os.environ.get("UI_BACKEND_URL", "http://127.0.0.1:5050")


def heartbeat(server: str, tool: str, args: dict, status: str = "ok", body: str | None = None) -> None:
    """Fire-and-forget POST to the UI backend so the demo UI can annotate
    "<server> saw: <tool>(<args>)" against in-UI and out-of-UI calls alike.

    Best-effort: if the UI backend isn't reachable we swallow the error so
    the MCP tool still returns successfully."""
    try:
        httpx.post(
            f"{UI_BACKEND_URL}/api/events",
            json={
                "type": "tool_invoked",
                "server": server,
                "tool": tool,
                "args": args,
                "status": status,
                "body": (body[:200] if isinstance(body, str) else body),
            },
            timeout=0.5,
        )
    except Exception:
        pass
