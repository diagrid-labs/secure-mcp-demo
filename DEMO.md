# DEMO.md — demo walkthrough

Shows Catalyst's per-tool access policy governing calls to the single
`postgresql-mcp` MCP server, across three roles — analyst, ops, admin.

Two ways to run it, same underlying policy either way:

- **[UI walkthrough](#ui-walkthrough)** — click through the demo UI.
- **[CLI walkthrough](#cli-walkthrough)** — `diagrid mcpserver access test`,
  one command per role.

For repo overview / architecture, see [README.md](README.md). For local
environment bring-up (Postgres, Keycloak, ngrok), see README.md's
"Pre-demo setup"; for Kubernetes, see [k8s/CATALYST.md](k8s/CATALYST.md).

## Setup (once)

Both walkthroughs assume the stack is running with the canonical ACL
matrix granted and Catalyst's own OAuth2 auth turned on:

```bash
./scripts/setup.sh   # Catalyst project, app-ids, MCPServer resource
./oauth2/setup.sh    # Catalyst's own OAuth2 auth — see README.md's "OIDC / bearer middleware"

diagrid mcpserver access grant postgresql-mcp --caller analyst-mcp-client --allow-tools query --project secure-mcp-demo --wait
diagrid mcpserver access grant postgresql-mcp --caller ops-mcp-client     --allow-tools query,insert_employee,update_salary --project secure-mcp-demo --wait
diagrid mcpserver access grant postgresql-mcp --caller admin-mcp-client   --allow-tools query,insert_employee,update_salary,delete_employee,truncate_table --project secure-mcp-demo --wait
```

| Operation | Tool(s) | Allowed roles |
|---|---|---|
| Query | `query` | analyst, ops, admin |
| Write | `insert_employee`, `update_salary` | ops, admin |
| Delete | `delete_employee`, `truncate_table` | admin |

## UI walkthrough

Open the demo UI (local: `http://localhost:5050` after `cd ui_backend && ./run.sh`;
k8s: the ingress URL from `k8s/CATALYST.md`).

1. **Query as analyst** — select `analyst`, click `Query`. Succeeds (`200`).
2. **Write as analyst** — click `Write` (calls `insert_employee`). Fails
   (`403`). Check Catalyst's API logs for the call — status `Forbidden`,
   since analyst isn't granted `insert_employee`.
3. **Write as ops** — switch to `ops`, click `Write`. Succeeds — a "Demo
   Target" employee is inserted.
4. **Delete as ops** — click `Delete`. Fails (`403`) — ops isn't granted
   `delete_employee`.
5. **Delete as admin** — switch to `admin`, click `Delete`. Succeeds —
   removes the "Demo Target" row inserted in step 3.

## CLI walkthrough

Same policy, checked directly against Catalyst's control plane — no MCP
call is actually made, so nothing in the database changes:

```bash
diagrid mcpserver access test postgresql-mcp --project secure-mcp-demo --caller analyst-mcp-client --tool query            # ALLOWED
diagrid mcpserver access test postgresql-mcp --project secure-mcp-demo --caller analyst-mcp-client --tool insert_employee  # DENIED
diagrid mcpserver access test postgresql-mcp --project secure-mcp-demo --caller ops-mcp-client     --tool insert_employee  # ALLOWED
diagrid mcpserver access test postgresql-mcp --project secure-mcp-demo --caller ops-mcp-client     --tool delete_employee  # DENIED
diagrid mcpserver access test postgresql-mcp --project secure-mcp-demo --caller admin-mcp-client   --tool delete_employee  # ALLOWED
```

## Reset between runs

```bash
./scripts/down.sh   # back to deny-all
```
