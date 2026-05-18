# secure-mcp-demo

Per-operation access control on MCP tool calls, enforced by Diagrid Catalyst,
with layered OIDC enforcement via Keycloak on destructive operations.

Three agents (`analyst`, `ops`, `admin`) with distinct Catalyst identities
probe four per-op MCP servers (`mcp-db-schema`, `mcp-db-query`,
`mcp-db-write`, `mcp-db-ddl`). Catalyst configurations control which
identity can invoke which operation. The destructive op (`mcp-db-ddl`)
additionally requires a valid Keycloak-issued JWT — step-up auth for
high-risk operations.

**Secure by default:** after `./setup.sh`, every operation is denied for
every agent. Access is granted progressively during the demo. The canonical
target matrix:

```
[analyst-agent]   schema:✓  query:✓  write:✗ (403)  ddl:✗ (403)
[ops-agent]       schema:✓  query:✓  write:✓        ddl:✗ (403)
[admin-agent]     schema:✓  query:✓  write:✓        ddl:✓ (with JWT)
```

Admin's `ddl` requires both:
1. Catalyst ACL allow (granted via `grant.sh ddl admin` or `up.sh`)
2. Valid Keycloak JWT presented as `Authorization: Bearer …`

Without the JWT, admin's ddl gets **HTTP 401 from the bearer middleware**
— even though the ACL allows it. Two independent gates.

Defense in depth: each per-op MCP server connects to Postgres as its own
DB role. Even if all upstream layers fail, the DB role caps what the
operation can actually execute.

---

## Running the demo

**For the full presenter's walkthrough — pre-demo setup, the 8 beats in
order, and reset between runs — see [DEMO.md](DEMO.md).**

This README documents architecture, file layout, and individual scripts.

---

## Prerequisites

- Docker (or OrbStack)
- `diagrid` CLI, logged in (`diagrid login`)
- `uv` (`brew install uv`)
- `ngrok` (free tier OK; needed to expose Keycloak to Catalyst's cloud edge)

---

## Architecture

```
Agents (local)              Catalyst Cloud                MCP servers (local)
────────────                ───────────────               ───────────────────
analyst-agent ──┐                                        ┌─ mcp-db-schema
ops-agent     ──┼─► dapr-api-token + ACL + bearer mw ──►├─ mcp-db-query
admin-agent   ──┘   (3-layer cloud-side enforcement)     ├─ mcp-db-write
                                                          └─ mcp-db-ddl
                                                                │
                                                                ▼
                                                       Postgres (role-scoped
                                                       DB users = floor)

         Keycloak (local docker + ngrok) ──► issues JWTs that the
                                              bearer middleware validates
```

Four enforcement layers, each independent:
1. **Catalyst token verification** — confirms calling app-id (workload identity)
2. **Catalyst ACL policies** — per-op authorization
3. **Bearer middleware** — JWT signature/audience/issuer validation
4. **Postgres role-scoped DB users** — last line of defense

Three teams own them (platform, IAM, data). An attacker must defeat all four.

---

## File layout

```
setup.sh                      Catalyst + OIDC setup (one shot, idempotent)
dev.yaml                      Dapr multi-app run file for 4 servers
run_demo.sh                   Matrix probe runner. Supports --no-jwt flag.
reset.sh                      Teardown stale dev sessions + orphan procs
schema.sql                    Postgres tables + role-scoped DB users
docker-compose.yaml           Postgres + Keycloak

servers/
  db_schema.py    db_query.py    db_write.py    db_ddl.py
  common.py                   Postgres connection helper
  test_all.py                 Standalone smoke test (no Catalyst)
  requirements.txt

agents/
  probe.py                    Matrix probe harness (optionally fetches JWT)
  agent.py                    LLM-driven scene script (legacy from step 2)
  requirements.txt

scripts/
  up.sh                       Apply canonical demo matrix in one shot
  down.sh                     Revoke everything — back to deny-all
  grant.sh <op> <agent>...    Additive grant (preserves other agents)
  revoke.sh <op> <agent>...   Additive revoke (preserves other agents)
  show_identity.sh            Token fingerprints for all 7 app-ids
  spoof.sh                    Catalyst-layer spoof attempts

oauth2/
  bearer-component.yaml       Dapr middleware Component (templated)
  config-ddl-oauth.yaml       Catalyst Configuration with appHttpPipeline
  setup.sh                    Re-apply OIDC layer (refresh JWKS cache)
  teardown.sh                 Remove OIDC layer
  spoof_oauth.sh              JWT-layer spoof attempts
  admin_workflow.sh           End-to-end success: insert + delete real rows
  admin_workflow.py           Admin's MCP calls (insert/delete actions)
  inspect_token.sh            Decode a JWT, compare with JWKS
  test_jwt.sh                 Single request with JWT, full HTTP response

keycloak/
  realm-export.json           Realm + shared M2M client + audience mapper

DEMO.md                       Presenter's walkthrough (start here for demos)
KNOWN_ISSUES.md               Upstream bugs and workarounds
TODO.md                       Backlog (gitignored)
```

---

## Individual script reference

### Matrix probe

```bash
./run_demo.sh                       # all 3 agents, uses JWT if env vars set
./run_demo.sh --no-jwt              # all 3 agents, ignore JWT (step-up beat)
./run_demo.sh analyst               # single role
./run_demo.sh --no-jwt analyst      # single role, no JWT
```

`run_demo.sh` reads each agent's Catalyst API token via `diagrid appid get`
and calls `probe.py` directly with `DAPR_HTTP_ENDPOINT` /
`DAPR_API_TOKEN` (+ optionally Keycloak vars) in env. It doesn't wrap each
agent in its own `diagrid dev run` — wrapping caused server-side tunnel
breakage (see [KNOWN_ISSUES.md](KNOWN_ISSUES.md)).

For **live LLM-driven scenes** (a single agent making real decisions), use
`diagrid dev run --app-id <agent>` interactively — Ctrl+C when done.

### Granting + revoking (additive)

```bash
./scripts/grant.sh <op> <agent>...
./scripts/revoke.sh <op> <agent>...
```

Both read the current configuration, modify only the named agents' entries,
and write back the full policy list. Other agents' entries are preserved.

Convenience:
```bash
./scripts/up.sh         # Apply canonical matrix (4 grant calls)
./scripts/down.sh       # Back to deny-all baseline
```

### Identity + spoofs

```bash
./scripts/show_identity.sh          # 7 app-ids with token fingerprints
./scripts/spoof.sh                  # 3 Catalyst-layer spoofs (no token / forged / wrong role)
./oauth2/spoof_oauth.sh             # 3 OIDC-layer spoofs (no JWT / malformed / wrong audience)
```

### End-to-end destructive workflow (success path)

```bash
./oauth2/admin_workflow.sh          # admin inserts + deletes a real row
```

Demonstrates both Catalyst ACL and OIDC bearer middleware accepting a
legitimate request. Self-resetting (insert + delete on the same row).

---

## Refreshing OIDC layer

If Keycloak rotates signing keys (e.g. after `docker-compose up -d --force-recreate keycloak`)
or the ngrok URL changes, refresh the bearer Component so Catalyst re-fetches
the JWKS:

```bash
export KEYCLOAK_PUBLIC_URL=https://...-new-url...
./oauth2/setup.sh
```

OIDC debug helpers:
```bash
./oauth2/inspect_token.sh           # decode a fresh JWT, compare kid with JWKS
./oauth2/test_jwt.sh                # single request with JWT, full response
```

To remove the OIDC layer entirely (revert to Catalyst-ACL-only):
```bash
./oauth2/teardown.sh
```

---

## Resetting state

### Between demo runs
If you see HTTP 502 on previously-working calls, Catalyst tunnel state is
stuck:

```bash
# Ctrl+C the diagrid dev run -f dev.yaml in Terminal 1, then:
./reset.sh
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

`reset.sh` stops all stale dev sessions + kills orphan server processes
on ports 8001–8004. App-ids and configurations stay intact.

### Full teardown
```bash
diagrid project delete secure-mcp-demo
docker-compose down -v
```
