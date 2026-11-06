# secure-mcp-demo

Per-tool access control on MCP tool calls, enforced by Diagrid,
with mandatory OIDC enforcement via Keycloak.

Three agents (`analyst`, `ops`, `admin`) with distinct Diagrid identities
call a single MCP server (`postgresql-mcp`) through Diagrid's MCP proxy
endpoint. Two independent gates apply to every call:

1. **Diagrid's MCPServer access policy** — per-tool ACL: which identity
   can invoke which tool.
2. **Keycloak JWT verification, in `postgresql_mcp.py` itself** — mandatory, not
   optional. Every call to `postgresql-mcp` requires a valid Keycloak-issued
   JWT, on top of the Diagrid dapr-api-token; the server checks its
   signature, issuer, and audience against Keycloak's JWKS before any tool
   runs. Per
   <https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials>,
   that JWT is **Diagrid's own** — fetched and attached automatically via
   OAuth2 client-credentials configured directly on the MCPServer resource,
   using Diagrid's own Keycloak client (`catalyst-proxy`). No agent ever
   fetches or presents a JWT itself. (There's no Dapr sidecar in this
   architecture to enforce this at the platform level — an MCPServer
   resource's app-id is Diagrid-managed and can't have a Configuration
   attached, so the check has to live in the application.)

**Secure by default:** after `./scripts/setup.sh`, the MCPServer access policy is
deny-all *and* nothing is configured to satisfy the JWT requirement — every
call fails regardless of ACL. The demo's step-up beat is `./oauth2/setup.sh`:
run it and Diagrid starts attaching its own JWT, and calls start succeeding
(gated from there purely by the ACL matrix). The canonical target matrix,
once both are set up:

```
[analyst-mcp-client]  query:✓  write:✗ (403)  delete:✗ (403)
[ops-mcp-client]      query:✓  write:✓        delete:✗ (403)
[admin-mcp-client]    query:✓  write:✓        delete:✓
```

Before `./oauth2/setup.sh` runs, every cell is `✗ (401)` — even for tools
the ACL already allows. That's the demo: turn Diagrid's own auth on, watch
the whole matrix come alive at once.

Defense in depth: even within the single MCP server, each tool group
connects to Postgres as its own DB role. Even if all upstream layers fail,
the DB role caps what each tool can actually execute.

A web UI for driving the demo lives in `ui_backend/` — see that directory
for setup. TL;DR: `cd ui_backend && ./run.sh`, then open `http://localhost:5050`.

---

## Running the demo

**For the full presenter's walkthrough — pre-demo setup, the demo beats in
order, and reset between runs — see [DEMO.md](DEMO.md).**

This README documents architecture, file layout, and individual scripts.

---

## Prerequisites

- Docker (or OrbStack)
- `diagrid` CLI, logged in (`diagrid login`)
- `uv` (`brew install uv`)
- `ngrok` (free tier OK; needed to expose Keycloak to Diagrid's cloud edge)

---

## Architecture

```
Agents (local)                    Catalyst Cloud                        MCP server (local)
────────────                      ───────────────                       ──────────────────
analyst-mcp-client ──┐                                                ┌─ query
ops-mcp-client     ──┼─► dapr-api-token ──► MCPServer ACL ──► own ───►├─ insert_employee
admin-mcp-client   ──┘     (no JWT)          (per-tool)      OAuth2   ├─ update_salary
                                                               JWT ──┐ ├─ delete_employee
                                                                      │└─ truncate_table
                                                                      │       │
                                          Keycloak (local docker      │       ▼
                                          + ngrok) ◄── client_______───┘  Postgres (role-scoped
                                          credentials                    DB users = floor)
                                          (catalyst-proxy client)
```

Diagrid — not any agent — fetches its own JWT from Keycloak and attaches
it to every call it forwards. Agents never see or handle a JWT at all.

Four enforcement layers, each independent:
1. **Diagrid App Id (token verification)** — confirms calling app-id
2. **MCPServer access policy** — per-tool authorization (filters `tools/list`; blocks `tools/call`)
3. **Keycloak JWT verification in `postgresql_mcp.py`** — signature/audience/issuer validation, app-wide, mandatory — the JWT is Diagrid's own, not the agent's
4. **Postgres role-scoped DB users** — last line of defense

Three teams own them (platform, IAM, data). An attacker must defeat all four.

### How Diagrid enforces tool-level access

Callers reach the MCP server only through Diagrid's MCP proxy endpoint:
`{DAPR_HTTP_ENDPOINT}/v1.0/diagrid/mcp/postgresql-mcp`. Enforcement happens in two ways:

- **Discovery is filtered.** `tools/list` returns only the tools the calling app-id
  is granted — an unauthorized tool is invisible, not merely un-callable.
- **Calls are gated.** An unauthorized `tools/call` is rejected with `403 Forbidden`
  before the request reaches the server.

---

## File layout

```
dev.yaml                      Dapr multi-app run file (single postgresql-mcp app)
schema.sql                    Postgres tables + role-scoped DB users
docker-compose.yaml           Postgres + Keycloak

resources/
  postgresql-mcp.yaml         MCPServer resource (points Catalyst at localhost:8001/mcp)

servers/
  postgresql_mcp.py           Combined FastMCP server; all tools in one process,
                              per-tool DB user selection, and Keycloak JWT verification
                              (TokenVerifier, checked on every call — see "OIDC / bearer
                              middleware" below)
  common.py                   Postgres connection helper + UI heartbeat hook
  requirements.txt

agents/
  probe.py                    Matrix probe harness (calls each tool via postgresql-mcp)
  agent.py                    LLM-driven scene script
  requirements.txt

scripts/
  setup.sh                    Catalyst project + App ID + MCPServer setup, and applies
                              mandatory Keycloak JWT bearer middleware on postgresql-mcp (idempotent)
  down.sh                     Revoke everything — back to deny-all
  reset.sh                    Teardown stale dev sessions + orphan procs

oauth2/
  setup.sh                    THE step-up demo beat: configures Catalyst's own OAuth2
                              client-credentials on the MCPServer resource (Catalyst ->
                              postgresql-mcp auth) — see "OIDC / bearer middleware" below.
                              No Dapr Component/Configuration involved — see that section
                              for why the old middleware approach doesn't apply here.
  teardown.sh                 Removes it — every call goes back to failing (401)
  admin_workflow.sh           End-to-end success: insert + delete real rows
  admin_workflow.py           Admin's MCP calls (insert/delete actions)

ui_backend/
  main.py                     FastAPI server: /api/employees, /api/policy,
                              /api/identity, /api/invoke, /api/events SSE
  run.sh                      Launcher (uvicorn on :5050)
  requirements.txt

ui/                           Web UI served by ui_backend at /
  index.html
  src/{state,console,result,app,atoms}.jsx
  src/styles.css
  colors_and_type.css
  assets/

k8s/                          Kubernetes deployment (Helm + Dockerfiles).
                              See k8s/README.md and k8s/CATALYST.md.

keycloak/
  realm-export.json           Realm (sslRequired: none — demo runs HTTP-only, no domain/TLS
                              yet) + the catalyst-proxy M2M client (Catalyst's own service
                              identity, see below) + audience mapper. No agent-facing client —
                              agents never talk to Keycloak.

DEMO.md                       Presenter's walkthrough (start here for demos)
```

---

## Individual script reference

### Matrix probe

```bash
export DAPR_HTTP_ENDPOINT=$(diagrid project get secure-mcp-demo -o json | jq -r '.status.endpoints.http.url')
export DAPR_API_TOKEN=$(diagrid appid get analyst-mcp-client --project secure-mcp-demo -o json | jq -r '.status.apiToken')
AGENT_ROLE=analyst uv run python agents/probe.py
```

`probe.py` hits `/v1.0/diagrid/mcp/postgresql-mcp` with the given agent's
Diagrid API token; Diagrid enforces which tools each agent can call. Swap
`analyst-mcp-client`/`AGENT_ROLE=analyst` for `ops`/`admin` to probe the other
roles. If every cell shows `401`, Diagrid's own OAuth2 auth isn't
configured on the MCPServer resource yet — turn it on from the demo UI, or
run `./oauth2/setup.sh`.

For **live LLM-driven scenes** (a single agent making real decisions), use
`diagrid dev run --app-id <agent>` interactively — Ctrl+C when done.

### Granting + revoking

```bash
diagrid mcpserver access grant  postgresql-mcp --caller <agent> --allow-tools <tools> --project secure-mcp-demo --wait
diagrid mcpserver access revoke postgresql-mcp --caller <agent> --allow-tools <tools> --project secure-mcp-demo --wait --approve
```

`<tools>` maps from op:
| op | tools |
|----|-------|
| `query` | `query` |
| `write` | `insert_employee`, `update_salary` |
| `delete` | `delete_employee`, `truncate_table` |

Convenience:
```bash
./scripts/down.sh       # Revoke every agent, every tool — back to deny-all baseline
```

There's no "up" equivalent — apply the canonical matrix live with the
`grant` command above, one caller at a time (see DEMO.md's setup step), or
through the demo UI.

To inspect or test the policy directly:
```bash
diagrid mcpserver access get postgresql-mcp
diagrid mcpserver access test postgresql-mcp --caller analyst-mcp-client --tool delete_employee
```

### End-to-end destructive workflow (success path)

```bash
./oauth2/admin_workflow.sh          # admin inserts + deletes a real row
```

Demonstrates both MCPServer access policy and bearer middleware accepting a
legitimate request. Self-resetting (insert + delete on the same row).

---

## OIDC / bearer middleware

Per <https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials>,
Diagrid's `MCPServer` resource can hold its own OAuth2 client-credentials
and fetch/attach a token on every call it forwards — this is **Diagrid
authenticating itself** to `postgresql-mcp`, not the calling agent. That's the
mechanism this demo's step-up beat is built on, end to end:

| Piece | What it does | Where |
|---|---|---|
| Keycloak JWT verification | Checks the bearer token's signature/issuer/audience against Keycloak's JWKS on every call; rejects with 401 if missing/invalid | `servers/postgresql_mcp.py` (`KeycloakTokenVerifier`, application code) |
| Diagrid OAuth2 client-credentials | Fetches Diagrid's own JWT via the `catalyst-proxy` Keycloak client and attaches it to every call Diagrid forwards | `spec.endpoint.streamableHTTP.auth.oauth2` on the MCPServer resource — `./oauth2/setup.sh` / `teardown.sh` |

No agent — and no code in `agents/`, `ui_backend/`, or `oauth2/admin_workflow.py`
— ever fetches or presents a JWT. That's entirely Diagrid's job.

The demo UI's console also lets you fetch an *illustrative* JWT for the
same `catalyst-proxy` client identity, purely for display (decoded
header/claims, raw `Authorization: Bearer …` line) — see the JWT preview
panel that appears once step-up is enabled. This is a separate
`client_credentials` call the UI backend makes directly against Keycloak
(`POST /api/jwt-preview`) — it is not, and cannot be, the literal token
Diagrid attaches on the wire to any given call; Diagrid's own token
exchange happens entirely inside Diagrid, invisible to any caller.

### Why the JWT check lives in application code, not a Dapr Component

Earlier iterations of this demo used a Dapr bearer-middleware Component +
Configuration (the classic Dapr way to require a JWT on inbound calls).
That doesn't work here: `postgresql-mcp`'s app-id is auto-provisioned and
Diagrid-managed by the MCPServer resource, and Diagrid rejects any
attempt to attach a Configuration to it (`diagrid appid update postgresql-mcp
--app-config ... ` → *"This App ID is managed and cannot be modified
directly"*). Confirmed live: with that Component/Configuration applied and
reporting `status: ready`, calls with no JWT anywhere still returned `200`
— it enforced nothing. Checking the full `MCPServer` resource schema
(`diagrid mcpserver schema`) confirms there's no inbound-auth field at all;
`auth.oauth2` / `auth.spiffe` / `headers` are all outbound (Diagrid→server)
only. So the check has to live in the app — `servers/postgresql_mcp.py` uses
the MCP SDK's own `TokenVerifier` protocol (`mcp.server.auth`), which wraps
the `/mcp` route in `RequireAuthMiddleware` automatically once you pass
`token_verifier=` + `auth=AuthSettings(...)` to `FastMCP(...)`.

**The demo:** postgresql-mcp always requires a JWT on every call, but nothing
supplies one until `./oauth2/setup.sh` configures Diagrid's own OAuth2
auth on the MCPServer resource — every call fails with `401` before that,
even the ones the MCPServer access policy already allows. Run it and
Diagrid starts attaching its own JWT automatically; calls succeed from
then on, gated purely by the ACL matrix. `./oauth2/teardown.sh` removes it,
putting every call back into deny.

```bash
# The demo beat — without this, everything 401s regardless of ACL
export KEYCLOAK_PUBLIC_URL=https://xxxx.ngrok-free.app  # or k8s ingress FQDN + /keycloak
export DIAGRID_PROJECT=secure-mcp-demo
./oauth2/setup.sh

# Revert to deny (everything 401s again)
./oauth2/teardown.sh
```

`postgresql_mcp.py` also needs `KEYCLOAK_PUBLIC_URL` / `KEYCLOAK_REALM` /
`KEYCLOAK_AUDIENCE` in its own process environment to build the JWKS URL it
verifies against — inherited from the shell in local dev (`dev.yaml`),
wired explicitly as pod env vars in the k8s chart
(`k8s/helm/secure-mcp/templates/mcp-servers.yaml`).

I validated this whole chain live against the deployed cluster: no
`Authorization` header → `401`; a garbage token → `401`; a real token
fetched from the live Keycloak via the `catalyst-proxy` client →
`200 OK` with a valid MCP session.

### Two gotchas hit while wiring up Diagrid's OAuth2 config (useful if you touch this feature elsewhere)

- The `issuer` field is **not** the OIDC issuer identifier despite the
  name — Diagrid does not perform discovery against
  `{issuer}/.well-known/openid-configuration`. It POSTs directly to
  whatever URL you put in `issuer`, so it must be the literal token
  endpoint (e.g. `.../protocol/openid-connect/token`), or Diagrid gets a
  plain `405 Method Not Allowed` from Keycloak's realm root. `oauth2/setup.sh`
  already bakes in the full token-endpoint path.
- Keycloak's default `sslRequired: "external"` rejects the token request
  with `403 invalid_request: "HTTPS required"` once it comes from a
  genuinely public IP (Diagrid's, not a private/internal one) over plain
  HTTP. This repo's realm sets `sslRequired: "none"` to match its existing
  HTTP-only, no-TLS-yet posture (see `k8s/CATALYST.md`'s "Future: real
  domain + TLS" section) — don't do this on a realm you actually care about
  protecting.

---

## Resetting state

### Between demo runs

If you see HTTP 502 on previously-working calls, Diagrid tunnel state is stuck:

```bash
# Ctrl+C the diagrid dev run -f dev.yaml in Terminal 1, then:
./scripts/reset.sh
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

`scripts/reset.sh` stops all stale dev sessions + kills any orphan server
process on port 8001. App-ids and MCPServer resource stay intact.

### Full teardown

```bash
diagrid project delete secure-mcp-demo
docker-compose down -v
```
