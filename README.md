# secure-mcp-demo

Per-operation access control on MCP tool calls, enforced by Diagrid Catalyst.

Three agents (`analyst`, `ops`, `admin`) with distinct identities probe four
per-op MCP servers (`mcp-db-schema`, `mcp-db-query`, `mcp-db-write`,
`mcp-db-ddl`). Catalyst configurations attached to each server app-id decide
which agent identities can invoke which operation.

**Secure by default:** after `./setup.sh`, every operation is denied for
every agent. Access is granted progressively via `./scripts/grant.sh`
during the demo. The canonical target matrix:

```
[analyst-agent]   schema:✓  query:✓  write:✗ (403)  ddl:✗ (403)
[ops-agent]       schema:✓  query:✓  write:✓        ddl:✗ (403)
[admin-agent]     schema:✓  query:✓  write:✓        ddl:✓
```

Defense in depth: each per-op MCP server connects to Postgres as its own DB
role, so even if a Catalyst ACL is misconfigured, the DB role caps what the
operation can actually execute.

---

## Prerequisites

- Docker (or OrbStack)
- `diagrid` CLI, logged in (`diagrid login`)
- `uv` (`brew install uv`)
- `OPENAI_API_KEY` available in env (only needed by LLM-driven scenes,
  not by the matrix probe)

---

## One-time setup

```bash
# 1. Install Python deps into a uv-managed venv
uv venv
uv pip install -r servers/requirements.txt
uv pip install -r agents/requirements.txt

# 2. Start Postgres with seed data + role-scoped DB users
docker-compose up -d

# 3. Create Catalyst project, 7 app-ids, 6 configurations
./setup.sh
```

`setup.sh` is idempotent — safe to re-run if you change configs.

---

## Run the matrix probe

Two terminals.

### Terminal 1 — long-running per-op MCP servers
```bash
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

Wait for all four `✅ Connected App ID … to http://localhost:800X` lines.

### Terminal 2 — fire the three agents
```bash
./run_demo.sh
```

All three matrix rows print back-to-back in a few seconds. No Ctrl+C, no
reset needed.

> **How it works:** `run_demo.sh` reads each agent's Catalyst API token
> from `diagrid appid get` and calls `probe.py` directly with
> `DAPR_HTTP_ENDPOINT` / `DAPR_API_TOKEN` in env — it does *not* wrap
> each agent in `diagrid dev run`. Wrapping each one-shot agent in its
> own dev session caused the server-side tunnels to break with "join
> token already consumed" errors. The servers still run under
> `diagrid dev run -f dev.yaml`, so Diagrid is the inbound/multi-app
> showcase. See `KNOWN_ISSUES.md` for the full dig.

For **live LLM-driven demo scenes** (a single agent making real decisions),
use `diagrid dev run --app-id <agent>` interactively — Ctrl+C when the
scene is done. The hang/cascade issue doesn't apply for one-shot
interactive runs.

---

## Granting + revoking access live

After `./setup.sh` everything is denied. Open access progressively during
the demo with `grant.sh`. Each call mutates the per-op Catalyst Configuration
in place — no app-id changes, no dev-session teardown, ~5s propagation.

```bash
./scripts/grant.sh <op> <agent>...
./scripts/grant.sh schema analyst ops admin
./scripts/grant.sh query  analyst ops admin
./scripts/grant.sh write  ops admin
./scripts/grant.sh ddl    admin
```

Revert specific grants:
```bash
./scripts/revoke.sh write analyst
./scripts/revoke.sh ddl   admin
```

### Convenience scripts

For rehearsal (or resetting state between runs) — apply / tear down the
canonical demo matrix in one command each:

```bash
./scripts/up.sh         # canonical matrix (read for all, write for ops/admin, ddl for admin)
./scripts/down.sh       # back to deny-all baseline
```

For the live demo, type the individual `./scripts/grant.sh ...` commands
so the audience watches each capability being opened up. Or type the raw
`diagrid` calls if you want the CLI itself on screen:

```bash
diagrid configuration update db-write --project secure-mcp-demo \
    --default-action deny --policy ops-agent:allow --policy admin-agent:allow
```

`run_demo.sh` takes an optional role arg (`analyst`, `ops`, or `admin`)
so you can re-probe just one identity after a grant.

---

## Identity + spoof demonstrations

Two more scripts for the "cryptographic identity" beat of the demo:

```bash
./scripts/show_identity.sh
```

Prints all seven app-ids with token prefixes + SHA-256 fingerprints —
proves each identity is a unique Catalyst-issued credential, not a
string in an ACL.

```bash
./scripts/spoof.sh
```

Runs three spoof attempts to show layered defenses:

| Attempt | Token | Target | Expected | Why |
|---|---|---|---|---|
| No token | none | `mcp-db-query` | HTTP 401 | rejected at edge, before any policy |
| Forged token | random string | `mcp-db-query` | HTTP 401 | token doesn't bind to any app-id |
| Real analyst token, wrong role | `analyst-agent`'s real | `mcp-db-ddl` | HTTP 403 | caller IS analyst, ACL denies analyst |

The point: an attacker can't escalate by mixing valid credentials with
another role's claim. The token *is* the identity.

---

## What's where

```
servers/
  db_schema.py   (port 8002)  list_tables, describe_table
  db_query.py    (port 8001)  query
  db_write.py    (port 8003)  insert_employee, update_salary
  db_ddl.py      (port 8004)  delete_employee, truncate_table
  common.py                   pg connection from env
  test_all.py                 standalone smoke test (no Catalyst)
agents/
  probe.py                    matrix-probe harness (used by run_demo.sh)
  agent.py                    LLM-driven scene (single role, one task)
schema.sql                    Postgres tables + role-scoped DB users
docker-compose.yaml           Postgres
setup.sh                      Catalyst project + app-ids + configs
dev.yaml                      multi-app run file for the 4 servers
run_demo.sh                   fires probe.py for each role
KNOWN_ISSUES.md               upstream bugs we're working around
```

---

## Resetting state

### Between demo runs (most common)

If you re-run the demo and see HTTP 502 on calls that should pass, the
Catalyst-side tunnel state is stuck from the prior run. Reset it:

```bash
# Stop server-side dev session: Ctrl+C in Terminal 1, then:
./reset.sh
```

Then start the servers again (`diagrid dev run -f dev.yaml`) and re-run
`./run_demo.sh`. `reset.sh` only stops dev sessions — app-ids and
configurations stay intact.

### Full teardown

```bash
diagrid project delete secure-mcp-demo
docker-compose down -v
```
