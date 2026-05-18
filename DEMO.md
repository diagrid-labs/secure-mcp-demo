# DEMO.md — presenter's walkthrough

This file is the script for running the secure-mcp demo live. Pre-demo
setup, eight beats in order, reset between runs, and troubleshooting.

For repo overview / architecture / file map, see [README.md](README.md).

---

## Pre-demo (one-time-ish, before the audience walks in)

Allow 5–10 minutes. Once Keycloak's ngrok URL and `setup.sh` have run,
the demo state persists until you `down.sh` or rebuild containers.

```bash
cd /Users/martezkillens/src/secure-mcp-demo
```

### 1. Postgres + Keycloak
```bash
docker-compose up -d
```

### 2. Expose Keycloak via ngrok
Catalyst's bearer middleware runs at the cloud edge and can't reach
`localhost:8080`. We tunnel.

```bash
# In a separate terminal — leave running for the whole session
ngrok http 8080 --host-header=localhost:8080
```
Copy the `https://` forwarding URL. Example: `https://abc-123.ngrok-free.app`.

### 3. Tell Keycloak its public hostname
This makes Keycloak stamp the JWT `iss` claim with the ngrok URL — matches
what Catalyst's middleware expects.

```bash
export KC_HOSTNAME_URL=https://abc-123.ngrok-free.app
docker-compose up -d --force-recreate keycloak
# wait ~30s for realm import
```

### 4. Tell setup.sh the same URL
```bash
export KEYCLOAK_PUBLIC_URL=https://abc-123.ngrok-free.app
```

### 5. Set agent-side JWT vars once for the session
You'll toggle JWT presentation per-call using the `--no-jwt` flag on
`run_demo.sh`, but the variables only need to be set once.

```bash
export KEYCLOAK_URL=http://localhost:8080
export KEYCLOAK_REALM=secure-mcp
export KEYCLOAK_CLIENT_ID=mcp-agent
export KEYCLOAK_CLIENT_SECRET=mcp-agent-secret
```

### 6. Catalyst project + app-ids + deny-all configs + OIDC middleware
```bash
./reset.sh                            # safety; clears stale Catalyst state
./setup.sh                            # all setup in one shot
```

### 7. Launch the MCP servers (Terminal 1 — leave running)
```bash
diagrid dev run --project secure-mcp-demo -f dev.yaml
```
Wait for all four `✅ Connected App ID` lines. Leave this terminal up
for the entire demo.

### 8. Open Terminal 2 alongside Terminal 1
This is where every beat below runs.

---

## On stage — the 8 beats

Terminal 2:

```bash
cd /Users/martezkillens/src/secure-mcp-demo
```

### Beat 1 — Secure by default

```bash
./run_demo.sh --no-jwt
```

**Expected:** every cell `✗ (HTTP 403)`.

> *"After setup, nothing is allowed. Twelve cells, twelve denials. We open
> access intentionally — that's the bar."*

### Beat 2 — Apply the canonical matrix, watch the step-up

```bash
./scripts/up.sh
./run_demo.sh --no-jwt
```

**Expected:** `analyst: ✓✓✗✗`, `ops: ✓✓✓✗`, `admin: ✓✓✓ ddl ✗ (HTTP 401)`

> *"One command opens the canonical access matrix — schema and query for
> everyone, write for ops and admin, ddl for admin. But look at admin's ddl
> row. Admin is allowed by the Catalyst ACL. The request still failed.*
>
> *"That 401 is the bearer middleware. The destructive operation requires
> a second proof — a JWT from our enterprise IdP. Catalyst lets the request
> through, the middleware blocks it. **Two independent gates.**"*

### Beat 3 — Present the JWT

```bash
./run_demo.sh
```

**Expected:** header now shows `(with Keycloak JWT)`; admin ddl flips to `✓`.

> *"Now the agent fetches a token from Keycloak using client_credentials —
> standard OIDC, same protocol every enterprise app uses for service-to-service.
> Presents it alongside the Catalyst token. Both gates pass."*

### Beat 4 — Hot revoke

```bash
./scripts/revoke.sh write ops
./run_demo.sh ops
```

**Expected:** ops write column flips `✓ → ✗`.

> *"Imagine off-boarding. Ops loses write access in seconds. No redeploy,
> no agent change, audit log captured it. Now restore."*

```bash
./scripts/grant.sh write ops
```

### Beat 5 — Cryptographic identity

```bash
./scripts/show_identity.sh
```

**Expected:** 7 app-ids with unique token prefixes + SHA-256 fingerprints.

> *"Policy reads in plain English — `analyst-agent: deny`. Enforcement is
> cryptographic. Catalyst resolves the token to an app-id before any
> policy rule fires. The names in the policy are labels; the identity
> behind them is a Catalyst-signed credential."*

### Beat 6 — Catalyst-layer spoofs

```bash
./scripts/spoof.sh
```

**Expected:** `HTTP 401`, `HTTP 401`, `HTTP 403`.

| Attempt | Defense | Code |
|---|---|---|
| No token | edge auth | 401 |
| Forged token | edge auth | 401 |
| Real analyst token used against mcp-db-ddl | ACL | 403 |

> *"Three failure modes, three different codes. And look at Terminal 1 —
> your MCP servers saw none of these requests."*

### Beat 7 — OIDC-layer spoofs

```bash
./oauth2/spoof_oauth.sh
```

**Expected:** `HTTP 401`, `HTTP 401`, `HTTP 401`.

| Attempt | Defense | Code |
|---|---|---|
| No JWT | middleware presence check | 401 |
| Malformed JWT | middleware signature check | 401 |
| Wrong audience | middleware `aud` claim check | 401 |

> *"Three more ways to fail at the JWT layer — and they all happen at the
> sidecar, never reaching the MCP server's application code. Defense in
> depth, cryptographic edition."*

### Beat 8 — Defense-in-depth floor

```bash
docker exec secure-mcp-postgres psql -U mcp_db_write demo \
    -c "DELETE FROM employees"
```

**Expected:** `ERROR: permission denied for table employees`

> *"And if all of that fails — every per-op MCP server connects to the
> database as its own role-scoped user. The write role we just exercised?
> It can INSERT, it can UPDATE. It cannot DELETE. Postgres caps it.
> Catalyst, agent, network — none of them can talk around the database
> role itself. **Four enforcement layers. Three teams own them. An
> attacker needs to defeat all four. You need to invent none of them.**"*

### Beat 9 — Closing beat: end-to-end success

```bash
./oauth2/admin_workflow.sh
```

**Expected:** three employee tables print (5 rows → 6 rows with "Demo
Target" visible → 5 rows again). Admin's INSERT goes through `mcp-db-write`,
Admin's DELETE goes through `mcp-db-ddl` with JWT.

> *"We've spent the last few minutes watching attackers fail. Here's what
> legitimate work looks like.*
>
> *"Admin authenticates to Catalyst. Admin presents a JWT to the IdP-backed
> middleware. Real INSERT through mcp-db-write — Demo Target appears on the
> books. Real DELETE through mcp-db-ddl — Demo Target is gone.*
>
> *"Same architecture that blocked four classes of attacker just enabled
> real destructive work in two API calls. That's enterprise-grade
> governance: hard to break, easy to use."*

---

## Reset for the next run

```bash
./scripts/down.sh                   # all policies back to deny-all
./run_demo.sh --no-jwt              # confirm all ✗ — ready to re-run Beat 1
```

---

## Troubleshooting

### HTTP 502 on previously-working calls
Catalyst tunnel state has gone stale. Bounce:

```bash
# Terminal 1: Ctrl+C the diagrid dev run
./reset.sh
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

### Admin still gets 401 on ddl even with `(with Keycloak JWT)` in the header
Catalyst's JWKS cache is stale (happens after Keycloak rotates signing keys).
Force a refresh:

```bash
./oauth2/setup.sh                   # re-applies the bearer Component
```
Wait ~30s for Catalyst to re-poll the JWKS, then retry.

### Admin ddl `✓` even without JWT env vars
The bearer middleware is failing open — Catalyst can't reach the JWKS URL.
Verify the ngrok tunnel is still alive and `KEYCLOAK_PUBLIC_URL` matches
the current ngrok URL. Re-run `./oauth2/setup.sh` if you've changed it.

### Stack feels stuck
Nuclear option: reset everything except Catalyst project membership.

```bash
# Terminal 1: Ctrl+C
./reset.sh
docker-compose down
docker-compose up -d
export KC_HOSTNAME_URL=https://...current-ngrok...
docker-compose up -d --force-recreate keycloak
# wait ~30s
./setup.sh
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

---

## Cheat sheet (the commands, no narration)

```bash
# Beat 1
./run_demo.sh --no-jwt

# Beat 2
./scripts/up.sh
./run_demo.sh --no-jwt

# Beat 3
./run_demo.sh

# Beat 4
./scripts/revoke.sh write ops
./run_demo.sh ops
./scripts/grant.sh write ops

# Beat 5
./scripts/show_identity.sh

# Beat 6
./scripts/spoof.sh

# Beat 7
./oauth2/spoof_oauth.sh

# Beat 8
docker exec secure-mcp-postgres psql -U mcp_db_write demo -c "DELETE FROM employees"

# Beat 9
./oauth2/admin_workflow.sh

# Reset
./scripts/down.sh
./run_demo.sh --no-jwt
```
