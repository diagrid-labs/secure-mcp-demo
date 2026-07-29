# DEMO.md — presenter's walkthrough

One demo, driven entirely through the web UI. This file is pre-demo setup,
the beats in order, reset between runs, and troubleshooting.

For repo overview / architecture / file map, see [README.md](README.md).

The goal is to show an audience how a database operation is governed by
layered controls:

1. **Catalyst App Id** resolves the caller from its Catalyst token.
2. **Catalyst's MCPServer access policy** decides whether that app id can
   invoke a specific *tool* on the single `mcp-server` app.
3. **`mcp-server` itself** verifies a valid JWT on **every** tool call,
   app-wide, always on — checked directly in application code
   (`servers/mcp_server.py`) against Keycloak's JWKS, since an
   MCPServer-resource-managed app-id has no Dapr sidecar to enforce this
   for it. The JWT is **Catalyst's own** — fetched via OAuth2
   client-credentials configured directly on the MCPServer resource, per
   <https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials>.
   No agent, and no code in the UI backend, ever fetches or presents a JWT
   that's actually used for auth — the UI can show an *illustrative* copy
   of a JWT for the same client identity (see Beat 3), but that's a
   separate, honest-display-only fetch, never what's forwarded on the wire.
4. **Postgres** applies the final database role boundary.

The UI is the surface the audience watches. A terminal is used only to
stage Catalyst state before the audience walks in, to reset between runs,
and — in Beat 5 — to type a couple of raw `diagrid` commands live, since
that's the one control-plane change (a hot ACL revoke) the UI doesn't
expose a button for.

> **Step-up control:** clicking "Turn on…"/"Turn off…" next to "Catalyst
> OAuth2 auth (Keycloak)" opens a confirmation modal before anything
> applies — it's deliberately not a one-click slider, since this is a real
> security-posture change. Confirming enable does two things: configures
> Catalyst's own OAuth2 auth on the MCPServer resource (the actual gate),
> and fetches a real, illustrative JWT via an independent `client_credentials`
> call against Keycloak's `catalyst-proxy` client — displayed below the
> button as a raw `Authorization` header plus decoded claims, with a live
> countdown to its ~15s expiry. That preview is honestly *not* the literal
> token Catalyst attaches to any specific call (Catalyst mints and attaches
> its own, invisibly) — it's shown purely to demonstrate what one looks like.

---

## Pre-demo setup (once per session)

Allow 5–10 minutes. Once this is done, state persists until you run
`./scripts/down.sh` / the UI's "Turn off…" or rebuild containers.

```bash
cd /path/to/secure-mcp-demo
```

### 1. Postgres + Keycloak

```bash
docker-compose up -d
```

### 2. Expose Keycloak via ngrok

Catalyst runs in the cloud and can't reach a bare `localhost:8080` when it
fetches its own token (Beat 3). We tunnel, and use the same public URL for
`mcp_server.py`'s own JWT verification so the issuer it checks against
matches the one Keycloak actually stamps into the token.

```bash
# In a separate terminal — leave running for the whole session
ngrok http 8080 --host-header=localhost:8080
```

Copy the `https://` forwarding URL. Example: `https://abc-123.ngrok-free.app`.

### 3. Tell Keycloak its public hostname

This makes Keycloak stamp the JWT `iss` claim with the ngrok URL — matches
the issuer `mcp_server.py` verifies every call against.

```bash
export KC_HOSTNAME_URL=https://abc-123.ngrok-free.app
docker-compose up -d --force-recreate keycloak
# wait ~30s for realm import
```

### 4. Export the same URL for mcp_server.py and the UI backend

```bash
export KEYCLOAK_PUBLIC_URL=https://abc-123.ngrok-free.app
```

`mcp_server.py` reads this (plus `KEYCLOAK_REALM` / `KEYCLOAK_AUDIENCE`,
defaulted in the script) to build the JWKS URL it verifies every call
against. The UI backend reads the same variable to configure/remove
Catalyst's own OAuth2 auth when you click the toggle in Beat 3 — export it
in whichever shell launches `ui_backend/run.sh` too (step 8 below).

### 5. Catalyst project + app-ids + deny-all ACL

```bash
./scripts/reset.sh                    # safety; clears stale Catalyst state
./scripts/setup.sh                    # all setup in one shot
```

This creates the Catalyst project, the 3 agent app-ids, and the single
`mcp-server` MCPServer resource — deny-all by default, no explicit "create
a deny policy" step needed.

### 6. Launch the MCP server (Terminal 1 — leave running)

```bash
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

Wait for the single `✅ Connected App ID` line — `mcp-server`. (All tools —
query, insert_employee, update_salary, delete_employee, truncate_table —
are served by this one combined app.) Leave this terminal up for the
entire demo.

This server process now requires a valid Keycloak JWT on every call —
`mcp_server.py` verifies it directly (signature, issuer, audience against
Keycloak's JWKS), since there's no Dapr sidecar to do it for an
MCPServer-resource-routed app. Nothing supplies that JWT yet — that's
Beat 3 below.

### 7. Launch the demo UI (Terminal 2 — leave running)

```bash
cd ui_backend
./run.sh
```

Open `http://localhost:5050/`.

### 8. Open Terminal 3 alongside Terminals 1–2

This is where Beat 5's two `diagrid` lines run.

> For a cloud/Kubernetes deployment instead of local `docker-compose` +
> ngrok, see `k8s/CATALYST.md` — same beats below, just swap the
> `KEYCLOAK_PUBLIC_URL` / Catalyst endpoint for the ingress FQDN.

---

## On stage — the beats

### Beat 1 — Secure by default

In the UI, with any role selected, click `Query`, `Write`, `Delete`.

**Expected — all three fail:**

- HTTP `403` on each.
- `Catalyst App Id` passes.
- `Catalyst ACL` fails — no rule allows this caller yet.
- `JWT middleware` shows "not reached".

> *"After setup, nothing is allowed. We open access intentionally — that's
> the bar."*

### Beat 2 — Apply the RBAC matrix — and watch it still fail

Apply the working policy from Terminal 3, one grant at a time so the
audience sees each capability appear and reads the actual control-plane
call, not a wrapped script:

```bash
diagrid mcpserver access grant mcp-server --caller analyst-agent --allow-tools query --project secure-mcp-demo --wait
diagrid mcpserver access grant mcp-server --caller ops-agent     --allow-tools query,insert_employee,update_salary --project secure-mcp-demo --wait
diagrid mcpserver access grant mcp-server --caller admin-agent   --allow-tools query,insert_employee,update_salary,delete_employee,truncate_table --project secure-mcp-demo --wait
```

| Operation | Tool(s) | Allowed agents |
|---|---|---|
| Query | `query` | analyst, ops, admin |
| Write | `insert_employee`, `update_salary` | ops, admin |
| Delete | `delete_employee`, `truncate_table` | admin |

In Catalyst, open the `mcp-server` MCPServer resource's access policy and
point out the role-to-tool grants.

In the UI, as `admin` (who the ACL now allows on all three tools), click
`Query`, `Write`, `Delete` again.

**Expected — all three still fail, but differently:**

- HTTP `401 Unauthorized` on each.
- `Catalyst App Id` passes.
- `Catalyst ACL` passes (admin is allowed all three tools).
- `JWT middleware` fails on each — nothing is configured to supply a JWT yet.
- The DB table does not change.

> *"This is RBAC at the MCP *tool* boundary, not the server boundary. The
> agent doesn't get broad database access, and it doesn't even get access to
> a whole server — it gets permission to invoke specific named tools on the
> one mcp-server app. But watch what happens when we actually try one: the
> ACL now allows all of this, and every call still fails. Catalyst's ACL is
> necessary, but it's not sufficient. mcp-server also demands a valid
> Keycloak JWT on every call, and right now nothing is supplying one. Two
> independent gates — passing the first doesn't get you through the second."*

In Catalyst API logs, filter by `mcp-server` and look at the tool name on
each call (`query`, `insert_employee`, `delete_employee`, …) to tell
operations apart — they're no longer separated by which server was hit,
since there's only one.

### Beat 3 — Turn on Catalyst's own OAuth2 auth — the step-up beat

In the UI, click "Turn on…" next to "Catalyst OAuth2 auth (Keycloak)" and
confirm in the modal.

This is the whole beat: Catalyst starts fetching its own JWT from Keycloak,
via its own dedicated client-credentials identity (`catalyst-proxy`), and
attaching it to every call it forwards to mcp-server. No agent did
anything differently — they never touch Keycloak at all. The UI also
fetches and displays a real, illustrative JWT for the same client identity
— a raw `Authorization: Bearer …` line, decoded header/claims, and a live
countdown to its ~15s expiry — purely to show what one looks like; it is
**not** the literal token Catalyst attaches to any specific call.

> *"Notice what actually stepped up: not the agent, not the UI — Catalyst
> itself. That's [Catalyst's own OAuth2 client-credentials support](https://docs.diagrid.io/develop/mcp/mcp-authentication#oauth-20-client-credentials):
> proving its own identity to your server, independent of who's calling
> through it."*

Re-run the same three admin calls: click `Query`, `Write`, `Delete` as
`admin`.

**Expected — all three now succeed:**

- HTTP `200 OK` on each.
- `Catalyst App Id` passes and shows a masked Catalyst token.
- `Catalyst ACL` passes.
- `JWT middleware` passes.
- The DB table reflects the write and the delete.

> *"We are not asking the audience to trust the UI. The UI shows the
> headers, Catalyst logs show the edge decision, and the table only changes
> when the database changes."*

### Beat 4 — Repeat the three operations, now differentiated by role

With Catalyst's OAuth2 auth still active from Beat 3, switch to `analyst`
and click `Query`, `Write`, `Delete`.

**Expected:**

- Query succeeds.
- Write fails at Catalyst ACL.
- Delete fails at Catalyst ACL.

> *"The JWT gate is open now for every call, but it's still not sufficient
> by itself. Catalyst enforces the per-tool ACL first, same as always.
> Catalyst proving its own identity doesn't turn analyst into admin — it
> just means the app-wide gate isn't the thing standing between analyst
> and delete anymore. The ACL still is."*

### Beat 5 — Hot revoke, live

From Terminal 3, revoke ops's write access directly — narrate this as a
real off-boarding action, not a demo-only affordance:

```bash
diagrid mcpserver access revoke mcp-server --caller ops-agent --allow-tools insert_employee,update_salary --project secure-mcp-demo --wait --approve
```

In the UI, switch to `ops` and click `Write`.

**Expected:** fails at Catalyst ACL (`403`) — the column that was green a
moment ago.

> *"Imagine off-boarding. Ops loses write access in seconds. No redeploy,
> no agent change, audit log captured it. Note this is still the ACL layer
> — Catalyst's own JWT is unaffected either way."*

Restore it:

```bash
diagrid mcpserver access grant mcp-server --caller ops-agent --allow-tools insert_employee,update_salary --project secure-mcp-demo --wait
```

Click `Write` as `ops` again to confirm it's back.

### Beat 6 — Show Catalyst graph and metrics

Move to Catalyst:

1. Open API logs and show the recent successful and failed calls.
2. Open the app graph and show `mcp-server` as the single downstream
   target for all three roles.
3. Open metrics and show request count / status distribution, and point
   out that individual tool calls (`query`, `insert_employee`,
   `delete_employee`, …) are still distinguishable within that one target.

> *"The separation is visible operationally even though it's one App Id now.
> Query, write, and delete are different *tools* on the same server, each
> independently governed by Catalyst's per-tool ACL, with one unified audit
> trail. The granularity moved from the server boundary to the tool
> boundary — that's why we can still reason about a destructive operation
> differently from a read."*

Close with:

> *"This is the demo in one sentence: the UI drives normal app behavior,
> while Catalyst and Keycloak make each security decision visible,
> auditable, and changeable without redeploying the agent or the MCP
> server — including Catalyst's own identity to that server."*

---

## Reset between runs

Back to deny-all on the ACL matrix (Terminal 3 — no UI button for this,
it edits the whole matrix at once rather than a single toggle):

```bash
./scripts/down.sh
```

In the UI, click "Turn off…" next to "Catalyst OAuth2 auth (Keycloak)" and
confirm — this reverts to Beat 2's "ACL says yes, JWT still says no" state
if you only want to rewind the step-up beat. Combined with `down.sh` above
it's a full reset to Beat 1's baseline.

Refresh the UI and run one denied call to confirm the baseline before the
next rehearsal or the live run.

---

## Troubleshooting

### HTTP 502 on previously-working calls

Catalyst tunnel state has gone stale. Bounce:

```bash
# Terminal 1: Ctrl+C the diagrid dev run, then:
./scripts/reset.sh
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

### Every call still 401s after Beat 3 ("Turn on…")

A few things to check, in order:

```bash
# Is Catalyst's OAuth2 auth actually configured on the resource?
diagrid mcpserver get mcp-server --project secure-mcp-demo -o json | jq '.spec.endpoint.streamableHTTP.auth'

# Is the resource itself healthy, or erroring on token fetch?
diagrid mcpserver get mcp-server --project secure-mcp-demo -o json | jq '.status'
```

A `405 Method Not Allowed` in the status message usually means
`KEYCLOAK_PUBLIC_URL` changed and the UI backend needs restarting with the
current ngrok URL exported (or click "Turn off…" then "Turn on…" again
after restarting it). An `HTTPS required` message means Keycloak's realm
`sslRequired` setting got reset to something other than `none` (re-import
`keycloak/realm-export.json`).

### Admin still gets 401 on delete even though Beat 3 already ran

Two different things can cause this — check which:

- Catalyst's own token fetch is failing: `diagrid mcpserver get mcp-server
  --project secure-mcp-demo -o json | jq '.status'` — see the previous
  troubleshooting entry.
- `mcp_server.py`'s own JWKS cache is stale (happens after Keycloak rotates
  signing keys — `PyJWKClient` re-fetches automatically on an unknown
  `kid`, but if it's still failing, bounce the server process):
  ```bash
  # Terminal 1: Ctrl+C the diagrid dev run, then:
  diagrid dev run --project secure-mcp-demo -f dev.yaml
  ```

### A call succeeds when it should still be denied by the ACL

That's a policy problem, not a JWT one — check:

```bash
diagrid mcpserver access get mcp-server --project secure-mcp-demo
```

### If the DB table does not change after a successful write/delete

```bash
curl -s "http://localhost:5050/api/employees" | jq '.rows | length'
```

Check the UI backend's own terminal output for errors.

### Stack feels stuck

Nuclear option: reset everything except Catalyst project membership.

```bash
# Terminal 1: Ctrl+C
./scripts/reset.sh
docker-compose down
docker-compose up -d
export KC_HOSTNAME_URL=https://...current-ngrok...
docker-compose up -d --force-recreate keycloak
# wait ~30s
export KEYCLOAK_PUBLIC_URL=https://...current-ngrok...
./scripts/setup.sh
diagrid dev run --project secure-mcp-demo -f dev.yaml
```

---

## Cheat sheet (the commands, no narration)

```bash
# Beat 2
diagrid mcpserver access grant mcp-server --caller analyst-agent --allow-tools query --project secure-mcp-demo --wait
diagrid mcpserver access grant mcp-server --caller ops-agent     --allow-tools query,insert_employee,update_salary --project secure-mcp-demo --wait
diagrid mcpserver access grant mcp-server --caller admin-agent   --allow-tools query,insert_employee,update_salary,delete_employee,truncate_table --project secure-mcp-demo --wait

# Beat 3 — click "Turn on…" in the UI

# Beat 5
diagrid mcpserver access revoke mcp-server --caller ops-agent --allow-tools insert_employee,update_salary --project secure-mcp-demo --wait --approve
diagrid mcpserver access grant  mcp-server --caller ops-agent --allow-tools insert_employee,update_salary --project secure-mcp-demo --wait

# Reset
./scripts/down.sh
# + click "Turn off…" in the UI
```
