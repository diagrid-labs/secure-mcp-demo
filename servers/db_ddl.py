from mcp.server.fastmcp import FastMCP

from common import get_connection

mcp = FastMCP("mcp-db-ddl", host="0.0.0.0", port=8004, stateless_http=True)


@mcp.tool()
def delete_employee(employee_id: int) -> str:
    """Delete an employee by id. Destructive."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM employees WHERE id = %s", (employee_id,))
            rowcount = cur.rowcount
            conn.commit()
            return f"Deleted {rowcount} row(s)"


@mcp.tool()
def truncate_table(table: str) -> str:
    """Truncate a table — removes all rows. Destructive, irreversible."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(f'TRUNCATE TABLE "{table}" RESTART IDENTITY CASCADE')
            conn.commit()
            return f"Truncated {table}"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
