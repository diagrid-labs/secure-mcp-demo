from mcp.server.fastmcp import FastMCP

from common import get_connection

mcp = FastMCP("mcp-db-query", host="0.0.0.0", port=8001, stateless_http=True)


@mcp.tool()
def query(sql: str) -> str:
    """Execute a read-only SQL query against the demo database."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            cols = [d[0] for d in cur.description] if cur.description else []
            rows = cur.fetchall()
            return str([dict(zip(cols, row)) for row in rows])


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
