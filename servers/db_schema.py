from mcp.server.fastmcp import FastMCP

from common import get_connection

mcp = FastMCP("mcp-db-schema", host="0.0.0.0", port=8002, stateless_http=True)


@mcp.tool()
def list_tables() -> str:
    """List all tables in the public schema."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = 'public' ORDER BY table_name"
            )
            return str([r[0] for r in cur.fetchall()])


@mcp.tool()
def describe_table(table: str) -> str:
    """Return column names and types for a given table."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT column_name, data_type FROM information_schema.columns "
                "WHERE table_schema = 'public' AND table_name = %s "
                "ORDER BY ordinal_position",
                (table,),
            )
            return str([{"column": c, "type": t} for c, t in cur.fetchall()])


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
