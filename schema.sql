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
-- Each per-op MCP server connects as its own DB role. Even if a Catalyst ACL
-- is misconfigured and the wrong agent reaches an operation, the DB role
-- caps what that operation can actually do.

CREATE ROLE mcp_db_query  WITH LOGIN PASSWORD 'query_pw';
CREATE ROLE mcp_db_schema WITH LOGIN PASSWORD 'schema_pw';
CREATE ROLE mcp_db_write  WITH LOGIN PASSWORD 'write_pw';
CREATE ROLE mcp_db_ddl    WITH LOGIN PASSWORD 'ddl_pw';

GRANT CONNECT ON DATABASE demo TO mcp_db_query, mcp_db_schema, mcp_db_write, mcp_db_ddl;
GRANT USAGE   ON SCHEMA public TO mcp_db_query, mcp_db_schema, mcp_db_write, mcp_db_ddl;

-- query: SELECT only
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_db_query;

-- schema: REFERENCES gives information_schema visibility (tables/columns)
-- without granting any data access. Tightest grant that still lets the role
-- introspect structure.
GRANT REFERENCES ON ALL TABLES IN SCHEMA public TO mcp_db_schema;

-- write: SELECT + INSERT + UPDATE (no DELETE, no DDL)
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO mcp_db_write;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO mcp_db_write;

-- ddl: full owner over the schema
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO mcp_db_ddl;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO mcp_db_ddl;
GRANT CREATE ON SCHEMA public TO mcp_db_ddl;
