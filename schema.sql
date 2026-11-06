-- Demo data ------------------------------------------------------------------

CREATE TABLE departments (
    id   SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE employees (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    email         TEXT NOT NULL UNIQUE,
    department_id INTEGER REFERENCES departments(id),
    salary        NUMERIC(10, 2),
    hired_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO departments (name) VALUES
    ('Engineering'),
    ('Sales'),
    ('Marketing'),
    ('Finance');

INSERT INTO employees (name, email, department_id, salary, hired_on) VALUES
    ('Alice Chen',     'alice@example.com', 1, 145000, '2021-03-15'),
    ('Bob Patel',      'bob@example.com',   1, 132000, '2022-07-01'),
    ('Carol Reyes',    'carol@example.com', 2,  95000, '2020-11-22'),
    ('Dan Okafor',     'dan@example.com',   3,  88000, '2023-01-10'),
    ('Eve Martinez',   'eve@example.com',   4, 110000, '2019-06-05');

-- Per-operation DB roles (defense in depth) ----------------------------------
-- Each per-op MCP server connects as its own DB role. Even if a Diagrid ACL
-- is misconfigured and the wrong agent reaches an operation, the DB role
-- caps what that operation can actually do.

CREATE ROLE mcp_db_query  WITH LOGIN PASSWORD 'query_pw';
CREATE ROLE mcp_db_write  WITH LOGIN PASSWORD 'write_pw';
CREATE ROLE mcp_db_delete WITH LOGIN PASSWORD 'delete_pw';

GRANT CONNECT ON DATABASE demo TO mcp_db_query, mcp_db_write, mcp_db_delete;
GRANT USAGE   ON SCHEMA public TO mcp_db_query, mcp_db_write, mcp_db_delete;

-- query: SELECT only
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_db_query;

-- write: SELECT + INSERT + UPDATE (no DELETE, no DDL)
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO mcp_db_write;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO mcp_db_write;

-- delete: full owner over the schema (covers DELETE + any DDL the demo needs)
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO mcp_db_delete;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO mcp_db_delete;
GRANT CREATE ON SCHEMA public TO mcp_db_delete;
