from mcp.server.fastmcp import FastMCP

from common import get_connection, heartbeat

mcp = FastMCP("mcp-db-write", host="0.0.0.0", port=8003, stateless_http=True)

SERVER = "mcp-db-write"


@mcp.tool()
def insert_employee(
    name: str, email: str, department_id: int, salary: float
) -> str:
    """Insert a new employee. Returns the new id."""
    args = {"name": name, "email": email, "department_id": department_id, "salary": salary}
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO employees (name, email, department_id, salary) "
                "VALUES (%s, %s, %s, %s) RETURNING id",
                (name, email, department_id, salary),
            )
            new_id = cur.fetchone()[0]
            conn.commit()
            body = f"Inserted employee id={new_id}"
            heartbeat(SERVER, "insert_employee", args, body=body)
            return body


@mcp.tool()
def update_salary(employee_id: int, new_salary: float) -> str:
    """Update an existing employee's salary."""
    args = {"employee_id": employee_id, "new_salary": new_salary}
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE employees SET salary = %s WHERE id = %s",
                (new_salary, employee_id),
            )
            rowcount = cur.rowcount
            conn.commit()
            body = f"Updated {rowcount} row(s)"
            heartbeat(SERVER, "update_salary", args, body=body)
            return body


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
